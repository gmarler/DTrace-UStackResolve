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

int related[uint64_t];

sched:::sleep
/ __PIDLIST__ || related[curlwpsinfo->pr_addr] /
{
  ts[curlwpsinfo->pr_addr] = timestamp;
}

sched:::wakeup
/ ts[args[0]->pr_addr] /
{
  this->d = timestamp - ts[args[0]->pr_addr];
  @[args[1]->pr_fname, args[1]->pr_pid, args[0]->pr_lwpid,
    args[0]->pr_wchan, stack(), ustack(), execname, pid,
    curlwpsinfo->pr_lwpid] = sum(this->d);
  ts[args[0]->pr_addr] = 0;
  /* also follow who wakes up the waker */
  related[curlwpsinfo->pr_addr] = 1;
}

tick-1sec
{
  printf("\n%Y\n",walltimestamp);

  printa("\n%s-%d/%d-%x%k-%k%s-%d/%d\n%@d\n",@);

  trunc(@);
}

tick-__RUNTIME__
{
  exit(0);
}
