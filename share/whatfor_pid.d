#pragma D option noresolve
#pragma D option quiet
#pragma D option ustackframes=100
#pragma D option bufsize=2m
#pragma D option aggrate=103Hz
#pragma D option aggsize=4m
#pragma D option switchrate=239Hz
#pragma D option cleanrate=353Hz
#pragma D option dynvarsize=10m

sched:::off-cpu
/ __PIDLIST__ &&
  curlwpsinfo &&
  curlwpsinfo->pr_state == SSLEEP /
{
  /*
   * We're sleeping.  Track our sobj type.
   */
  self->sobj = curlwpsinfo->pr_stype;
  self->bedtime = timestamp;
}

sched:::off-cpu
/ __PIDLIST__ &&
  curlwpsinfo &&
  curlwpsinfo->pr_state == SRUN /
{
  self->bedtime = timestamp;
}

sched:::on-cpu
/self->bedtime && !self->sobj/
{
  @["preempted",pid,tid,stack(),ustack()] = quantize(timestamp - self->bedtime);
  self->bedtime = 0;
}

sched:::on-cpu
/self->sobj/
{
  @[self->sobj == SOBJ_MUTEX ? "kernel-level lock" :
    self->sobj == SOBJ_RWLOCK ? "rwlock" :
    self->sobj == SOBJ_CV ? "condition variable" :
    self->sobj == SOBJ_SEMA ? "semaphore" :
    self->sobj == SOBJ_USER ? "user-level lock" :
    self->sobj == SOBJ_USER_PI ? "user-level prio-inheriting lock" :
    self->sobj == SOBJ_SHUTTLE ? "shuttle" : "unknown",
    pid,tid,stack(),ustack()] = quantize(timestamp - self->bedtime);

  self->sobj = 0;
  self->bedtime = 0;
}

tick-1sec
{
  printf("\n%Y\n",walltimestamp);

  printf("%-32s %5s %-3s %-12s\n","SOBJ OR PREEMPTED","PID","TID","LATENCY(ns)");
  printa("%-32s %5d %-3d %-@12u %k %k\n",@);

  trunc(@);
}
