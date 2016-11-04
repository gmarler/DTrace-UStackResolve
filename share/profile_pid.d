#pragma D option noresolve
#pragma D option quiet
#pragma D option ustackframes=__USTACK_FRAMES__
#pragma D option bufsize=16m
#pragma D option aggrate=223Hz
#pragma D option aggsize=6m
#pragma D option switchrate=239Hz
#pragma D option cleanrate=353Hz
#pragma D option dynvarsize=64m

profile-297Hz
/ __PIDLIST__ /
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


