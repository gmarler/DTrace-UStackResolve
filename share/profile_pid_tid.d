#pragma D option noresolve
#pragma D option quiet
#pragma D option ustackframes=__USTACK_FRAMES__
#pragma D option bufsize=__BUFSIZE__
#pragma D option aggrate=__AGGRATE__
#pragma D option aggsize=__AGGSIZE__
#pragma D option switchrate=__SWITCHRATE__
#pragma D option cleanrate=__CLEANRATE__
#pragma D option dynvarsize=__DYNVARSIZE__

profile-297Hz
/ __PIDLIST__ &&
  (tid == __TID__) /
{
  @s[pid,tid,stack(),ustack()] = count();
}

tick-1sec
{
  printf("\n%Y\n",walltimestamp);

  /* We prefix with PID:<pid> so that we can determine which PID we're working
   * on, on the off chance that individual PIDs have set LD_LIBRARY_PATH or
   * similar, such that some shared libraries differ, even though the
   * execpath (fully qualified path to an executable), execname (basename)
   * of the same executable), and SHA-1 of the executable are all
   * identical between PIDs.
   */
  printa("PID:%-5d %-3d %k %k %@12u\n",@s);

  trunc(@s);
}

tick-__RUNTIME__
{
  exit(0);
}
