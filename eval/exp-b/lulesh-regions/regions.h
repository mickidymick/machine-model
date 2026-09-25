/* lulesh-regions: per-phase hardware counters for LULESH's time step.
 *
 * GROUND-TRUTH INSTRUMENT ONLY. This measures the test application, so nothing
 * it produces may reach a machines/ descriptor or any arm's directory. It lives beside
 * pristine-lulesh/, never inside it, because setup.sh copies pristine-* into the
 * arms verbatim.
 *
 * Why it exists: profile_wrap.sh measured LULESH's loop at 30-42% of peak DRAM
 * bandwidth and IPC 0.68 (job 5545917) -- "not saturated ON AVERAGE". A whole-run
 * average over ~15 kernels cannot say whether some kernels saturate while others
 * idle, and IBS, which would separate them from outside, is refused on Frontier.
 * So we separate them from inside.
 *
 * Method: markers partition the time step. rg_mark(r) reads every OpenMP
 * thread's counters and charges the delta since the previous mark to the region
 * that was open, then opens r. Every counted event lands in exactly one region,
 * so the regions must SUM to the whole -- the merge checks that against
 * profile_wrap's independent total.
 *
 * Counting is per THREAD (PAPI's default, the one granularity Frontier's PAPI
 * honours in-process): each OpenMP thread opens its own event set on itself, and
 * each mark reads them all from inside a parallel region. That is only correct
 * if thread i is the same OS thread in every parallel region, so every read
 * checks gettid() against the one recorded at init -- a changed identity makes
 * the profile untrustworthy instead of silently mis-charged.
 *
 * Idle workers count too: a worker spin-waiting through a serial section or an
 * MPI wait accrues cycles and instructions there. That is real machine time, and
 * the per-thread values are kept so the merge can separate master from workers.
 */
#ifndef LULESH_REGIONS_H
#define LULESH_REGIONS_H

#include <papi.h>
#ifdef _OPENMP
#include <omp.h>
#else
/* The MPI-only build (build_spread.sh's lulesh-mpi) has no OpenMP: one thread,
 * and the pragmas below compile away. Lets the 64x1 config be profiled too. */
static inline int omp_get_max_threads(void) { return 1; }
static inline int omp_get_num_threads(void) { return 1; }
static inline int omp_get_thread_num(void)  { return 0; }
#endif
#include <pthread.h>
#include <sys/syscall.h>
#include <sys/stat.h>
#include <unistd.h>
#include <time.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum {
   RG_TIMEINC,       /* TimeIncrement: dt reduction across ranks = load-imbalance wait */
   RG_FORCE_SETUP,   /* post SBN receives, zero nodal forces */
   RG_STRESS,        /* InitStressTerms + IntegrateStressForElems + volume check */
   RG_HOURGLASS,     /* CalcHourglassControlForElems (FB hourglass force) */
   RG_FORCE_COMM,    /* send + sum nodal forces across ranks */
   RG_NODAL,         /* acceleration, BCs, velocity, position */
   RG_POSVEL_COMM,   /* SEDOV_SYNC_POS_VEL_EARLY exchange */
   RG_KINEMATICS,    /* CalcLagrangeElements */
   RG_QGRAD,         /* allocate gradients, post receives, monotonic-Q gradients */
   RG_Q_COMM,        /* exchange gradients */
   RG_QREGION,       /* CalcMonotonicQForElems + qstop scan */
   RG_EOS,           /* ApplyMaterialPropertiesForElems -- -c scales its repeats */
   RG_VOLUMES,       /* UpdateVolumesForElems */
   RG_TIMECONSTR,    /* Courant + hydro constraints */
   RG_N
};
static const char *RG_NAME[RG_N] = {
   "time_increment", "force_setup", "stress", "hourglass", "force_comm",
   "nodal_update", "posvel_comm", "kinematics", "q_gradients", "q_comm",
   "q_region", "eos", "volumes", "time_constraints",
};

/* Same five events, same order, as frontier/src/papi_launch.c -- see the
 * comments there for why ANY_ and not DEMAND_ fills, and why not a sixth. */
#define RG_NEV 5
static const char *RG_EVENTS[RG_NEV] = {
   "PAPI_TOT_INS", "PAPI_TOT_CYC", "PAPI_TLB_DM",
   "ANY_DATA_CACHE_FILLS_FROM_SYSTEM:MEM_IO_LCL",
   "ANY_DATA_CACHE_FILLS_FROM_SYSTEM:MEM_IO_RMT",
};
static const char *RG_KEYS[RG_NEV] = {
   "instructions", "cycles", "dtlb_load_misses",
   "dram_fills_local", "dram_fills_remote",
};

#define RG_MAXTHR 256
static int        rg_on = 0;
static char       rg_why_off[256] = "rg_init never ran";
static int        rg_nthr = 0;
static int        rg_set[RG_MAXTHR];
static long       rg_tid[RG_MAXTHR];
static long long  rg_last[RG_MAXTHR][RG_NEV];
static long long  rg_acc[RG_N][RG_MAXTHR][RG_NEV];
static double     rg_sec[RG_N];
static long       rg_calls[RG_N];
static int        rg_cur = -1;
static double     rg_t_last = 0;
static int        rg_tid_changed = 0, rg_team_short = 0, rg_read_err = 0;

static double rg_now(void)
{
   struct timespec t;
   clock_gettime(CLOCK_MONOTONIC, &t);
   return t.tv_sec + 1e-9 * t.tv_nsec;
}

static unsigned long rg_self(void) { return (unsigned long)pthread_self(); }

static void rg_init(void)
{
   int v = PAPI_library_init(PAPI_VER_CURRENT);
   if (v != PAPI_VER_CURRENT) {
      snprintf(rg_why_off, sizeof rg_why_off, "PAPI_library_init returned %d", v);
      return;
   }
   if (PAPI_thread_init(rg_self) != PAPI_OK) {
      snprintf(rg_why_off, sizeof rg_why_off, "PAPI_thread_init failed");
      return;
   }
   rg_nthr = omp_get_max_threads();
   if (rg_nthr > RG_MAXTHR) {
      snprintf(rg_why_off, sizeof rg_why_off, "%d threads > RG_MAXTHR", rg_nthr);
      return;
   }
   int fail = 0;
   char why[256] = "";
#pragma omp parallel num_threads(rg_nthr)
   {
      int i = omp_get_thread_num();
      int ok = (omp_get_num_threads() == rg_nthr);
      rg_tid[i] = syscall(SYS_gettid);
      rg_set[i] = PAPI_NULL;
      PAPI_register_thread();
      if (ok && PAPI_create_eventset(&rg_set[i]) != PAPI_OK) ok = 0;
      for (int e = 0; ok && e < RG_NEV; e++) {
         int rc = PAPI_add_named_event(rg_set[i], (char *)RG_EVENTS[e]);
         if (rc != PAPI_OK) {
            ok = 0;
#pragma omp critical
            snprintf(why, sizeof why, "thread %d: %s: %s", i, RG_EVENTS[e], PAPI_strerror(rc));
         }
      }
      if (ok && PAPI_start(rg_set[i]) != PAPI_OK) ok = 0;
      if (ok && PAPI_read(rg_set[i], rg_last[i]) != PAPI_OK) ok = 0;
      if (!ok) {
#pragma omp atomic write
         fail = 1;
      }
   }
   if (fail) {
      snprintf(rg_why_off, sizeof rg_why_off, "%s", why[0] ? why : "event set setup failed");
      return;
   }
   memset(rg_acc, 0, sizeof rg_acc);
   rg_on = 1;
   rg_why_off[0] = 0;
   rg_cur = -1;
   rg_t_last = rg_now();
}

/* Close the open region and open r (r < 0 opens nothing). Called by the master
 * thread outside any parallel region -- every call site in the patch is. */
static void rg_mark(int r)
{
   if (!rg_on) return;
   double t = rg_now();
   int cur = rg_cur;
#pragma omp parallel num_threads(rg_nthr)
   {
      int i = omp_get_thread_num();
      if (omp_get_num_threads() != rg_nthr) {
#pragma omp atomic write
         rg_team_short = 1;
      }
      if (syscall(SYS_gettid) != rg_tid[i]) {
#pragma omp atomic write
         rg_tid_changed = 1;
      }
      long long v[RG_NEV];
      if (PAPI_read(rg_set[i], v) != PAPI_OK) {
#pragma omp atomic write
         rg_read_err = 1;
      } else {
         if (cur >= 0)
            for (int e = 0; e < RG_NEV; e++) rg_acc[cur][i][e] += v[e] - rg_last[i][e];
         memcpy(rg_last[i], v, sizeof v);
      }
   }
   if (cur >= 0) { rg_sec[cur] += t - rg_t_last; rg_calls[cur]++; }
   rg_cur = r;
   rg_t_last = t;
}

static void rg_finish(int rank, double elapsed, long cycles)
{
   rg_mark(-1);
   if (rg_on) {
#pragma omp parallel num_threads(rg_nthr)
      {
         long long v[RG_NEV];
         PAPI_stop(rg_set[omp_get_thread_num()], v);
      }
   }
   const char *dir = getenv("RG_OUTDIR");
   if (!dir || !*dir) dir = "./regions.d";
   mkdir(dir, 0755);
   char path[4096];
   snprintf(path, sizeof path, "%s/rank%d.json", dir, rank);
   FILE *f = fopen(path, "w");
   if (!f) { perror(path); return; }
   fprintf(f, "{\n  \"rank\": %d,\n  \"enabled\": %s,\n  \"why_disabled\": \"%s\",\n",
           rank, rg_on ? "true" : "false", rg_why_off);
   fprintf(f, "  \"threads\": %d,\n  \"timesteps\": %ld,\n  \"elapsed_seconds\": %.6f,\n",
           rg_nthr, cycles, elapsed);
   fprintf(f, "  \"thread_identity_stable\": %s,\n  \"full_team_every_read\": %s,\n"
              "  \"read_errors\": %s,\n",
           rg_tid_changed ? "false" : "true", rg_team_short ? "false" : "true",
           rg_read_err ? "true" : "false");
   fprintf(f, "  \"keys\": [");
   for (int e = 0; e < RG_NEV; e++) fprintf(f, "%s\"%s\"", e ? ", " : "", RG_KEYS[e]);
   fprintf(f, "],\n  \"regions\": [\n");
   for (int r = 0; r < RG_N; r++) {
      fprintf(f, "    {\"name\": \"%s\", \"calls\": %ld, \"seconds\": %.6f, \"per_thread\": [",
              RG_NAME[r], rg_calls[r], rg_sec[r]);
      for (int i = 0; i < rg_nthr; i++) {
         fprintf(f, "%s[", i ? ", " : "");
         for (int e = 0; e < RG_NEV; e++) fprintf(f, "%s%lld", e ? ", " : "", rg_acc[r][i][e]);
         fprintf(f, "]");
      }
      fprintf(f, "]}%s\n", r + 1 < RG_N ? "," : "");
   }
   fprintf(f, "  ]\n}\n");
   fclose(f);
}

#endif
