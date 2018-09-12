#pragma D option noresolve
#pragma D option quiet
#pragma D option ustackframes=__USTACK_FRAMES__
#pragma D option bufsize=__BUFSIZE__
#pragma D option aggrate=__AGGRATE__
#pragma D option aggsize=__AGGSIZE__
#pragma D option switchrate=__SWITCHRATE__
#pragma D option cleanrate=__CLEANRATE__
#pragma D option dynvarsize=__DYNVARSIZE__
#pragma D option nworkers=__NWORKERS__

sched:::off-cpu
/ __PIDLIST__ /
{
  self->bedtime = timestamp;
}

sched:::on-cpu
/ self->bedtime /
{
  @[pid,tid,stack(),ustack()] = sum(timestamp - self->bedtime);
  self->bedtime = 0;
}

tick-1sec
{
  printf("\n%Y [%u]\n",walltimestamp,walltimestamp);

  printa("PID: %5d TID: %5d  %k %k %@12u\n",@);

  trunc(@);
}

tick-__RUNTIME__
{
  exit(0);
}
