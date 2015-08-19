package DTrace::UStackResolve;

use strict;
use warnings;

use Moose;
use namespace::autoclean;
use IO::Async;
use IO::Async::Loop;
use Future;
use CHI;

# VERSION
#
# ABSTRACT: Resolve User Stacks from DTrace for Large Binaries

=head1 SYNOPSIS

=head1 DESCRIPTON

With larger binaries, it's often the case that using DTrace's C<ustack()>
action will take very long amounts of time to complete the symbol table
lookups - often long enough to make DTrace abort because it appears
"unresponsive".

With the advent of this DTrace pragma:

#pragma D option noresolve

the output of the C<ustack()> action will be unresolved, for resolution
later.

The purpose of this module is to perform that resolution.

=cut

=head1 ATTRIBUTES

=cut

# Constants
has 'PMAP' => (
  init_arg    => undef,
  is          => 'ro',
  isa         => 'Str',
  default     => "/bin/pmap",
);

has 'NM' => (
  init_arg    => undef,
  is          => 'ro',
  isa         => 'Str',
  default     => "/usr/ccs/bin/nm",
);

has 'PGREP' => (
  init_arg    => undef,
  is          => 'ro',
  isa         => 'Str',
  default     => "/bin/pgrep",
);

has 'DTRACE' => (
  init_arg    => undef,
  is          => 'ro',
  isa         => 'Str',
  default     => "/sbin/dtrace",
);

# Real Attributes
has 'loop' => (
  is          => 'ro',
  isa         => 'IO::Async::Loop',
  default     => sub { IO::Async::Loop->new; },
);

has 'execname' => (
  is          => 'ro',
  isa         => 'Str',
  #builder     => '_build_execname',
  required    => 1,
);

# The modification time(s) of the execname we started this up
# for.  The point of this is to detect when the value increases,
# indicating that we need to recalculate the:
# - symbol cache
# - Red-Black symbol lookup tree
# - direct lookup cache
# TODO: A check for this should be done whenever a new PID is detected
#       in the DTrace output
has 'execname_mtime' => (
  is          => 'rw',
  isa         => 'HashRef[Int]',
);

has 'pids' => (
  is          => 'rw',
  isa         => 'ArrayRef[Int]',
  default     => sub { [ ]; },
  builder     => '_build_pids',
  lazy        => 1,
);

has 'dynamic_library_paths' => (
  is          => 'rw',
  isa         => 'ArrayRef[Str]',
  builder     => '_build_dynamic_library_paths',
  lazy        => 1,
  clearer     => '_clear_dynamic_library_paths',
  predicate   => '_has_dynamic_library_paths',
);

has 'symbol_table' => (
  is          => 'rw',
  isa         => 'HashRef[Str]',
  builder     => '_build_symbol_table',
  lazy        => 1,
  clearer     => '_clear_symbol_table',
  predicate   => '_has_symbol_table',
);


has 'symbol_table_cache' => (
  is          => 'ro',
  builder     => '_build_symbol_table_cache',
  lazy        => 1,
);

#
# Allow user stack frame depth to be chosen, but default to nothing, since
# it's very likely we'll want the full user stack most of the time.
#
has 'user_stack_frames' => (
  is          => 'ro',
  isa         => 'Str',
  default     => '',
);

sub _build_symbol_table_cache {
  my ($self) = shift;

  # TODO: Allow constructor to pass in a directory to hold the caches
  CHI->new( 
            #driver       => 'BerkeleyDB',
            driver       => 'File',
            cache_size   => '1024m',
            #root_dir     => '/bb/pm/data/symbol_tables',
            root_dir     => '/tmp/symbol_tables',
            namespace    => 'symbol_tables',
            on_get_error => 'warn',
            on_set_error => 'warn',
            l1_cache => { driver => 'RawMemory', global => 0, max_size => 64*1024*1024 }
           );
}



=head1 METHODS

=cut

=method shared_libs_for_pid

The unresolved ustack()'s produced by DTrace are unfortunately not fully
qualified, so you're not sure where they're coming from, nor are you sure
whether you should be looking for the 32-bit or 64-bit variant of those
libraries (although you could likely deduce the latter easily).

This method performs a pldd on the selected PID, obtaining the fully qualified
pathnames for all shared libraries used by it.

TODO: Raise an exception if there is more than one library with the same
basename, as unresolved ustack() calls emit each user stack frame like so:

<library basename>:0x<hex address>

If there are duplicate basenames, we really need to know that, as they're
assumed to be unique throughout the system.

=cut



=method shared_libs_for_binary

Similar to shared_libs_for_pid, just does the same via ldd for a binary on disk,
rather than a live PID.

=cut

=head1 BUILDERS

=cut

sub _build_pids {
  my ($self) = shift;

  my $execname = $self->execname; 
  my @output = capture( "$PGREP -lxf '^$execname.+'" );
  chomp(@output);
  say "PIDS:";
  say join("\n",@output);
  #say Dumper( \@output );
  my @pids = map { my $line = $_; $line =~ m/^(?:\s+)?(?<pid>\d+)\s+/; $+{pid}; } @output;
  #say Dumper( \@pids );
  return \@pids;
}

sub _build_dynamic_library_paths {
  my ($self) = shift;

  # NOTE: It's likely we don't need to bother caching this, as it's really
  #       quick.
  # TODO: Check whether this has already been stored for this PID instance, using
  #       KEY: { pid => $pid, start_epoch => $start_epoch }
  #       Return immediately if available
  my @pids = @{$self->pids};
  my $PMAP = $self->PMAP;
  my %libpath_map;
  
  # Dynamic .so library analysis
  my $so_regex =
    qr{
       ^ (?<base_addr>[0-9a-fA-F]+) \s+         # Hex starting address
         \S+                        \s+         # size
         \S+                        \s+         # perms
         (?<libpath>/[^\n]+?\.so(?:[^\n]+|)) \n # Full path to .so* file
      }smx;

  # This relies on the fact that the first time a lib is listed in pmap output
  # is the actual offset we're always looking for.
  # NOTE: We don't need the base_addr anymore, so we simply ignore it now
  foreach my $pid (@pids) { 
    my $pmap_output = capture( "$PMAP $pid" );
    while ($pmap_output =~ m{$so_regex}gsmx) {
      $libpath_map{$+{libpath}}++;
    }
  } 

  # Return the list of absolute library paths
  return [ keys %libpath_map ];
}

# Given a path to a dynamic/shared library or an executable,
# generate the symbol table.
# The #pragma for noresolve ensures each generated symbol will be of the
# form <entity>:<offset from base of entity>
#
# This means that we can use the symbol table with base address assumed to be
# implicitly 0 to resolve symbols without further work.
#

# TODO: Turn this from a normal builder into a Future
sub _build_symbol_table {
  my ($self) = shift;
  # TODO: fix this, as we'll need to get these from other attributes instead
  my ($exec_or_lib_path, $exec_or_lib_sha1) = @_;

  my ($NM) = $self->NM;


  # $start_offset is the offset of the _START_ symbol in a library or exec
  my ($symtab_aref,$symcount,$_start_offset);

  # TODO: Check whether data is in cache; return immediately if it is

  say "Building symtab for $exec_or_lib_path";
  # TODO: Convert to IO::Async::Process
  my $out       = capture( "$NM -C -t d $exec_or_lib_path" );

  say "CAPTURED " . length($out) . " BYTES OF OUTPUT FROM nm FOR $exec_or_lib_path";

  say "Parsing nm output for: $exec_or_lib_path";
  while ($out =~ m/^ [^|]+                           \|
                     (?:\s+)? (?<offset>\d+)         \| # Offset from base
                     (?:\s+)? (?<size>\d+)           \| # Size
                     (?<type>(?:FUNC|OBJT)) (?:\s+)? \| # A Function (or _START_ OBJT)
                     [^|]+                           \|
                     [^|]+                           \|
                     [^|]+                           \|
                     (?<funcname>[^\n]+)    \n
                  /gsmx) {
    my ($val);
    #say "MATCHED: $+{funcname}";
    if (not defined($_start_offset)) {
      if ($+{funcname} eq "_START_") {
        say "FOUND _START_ OFFSET OF: $+{offset}";
        $_start_offset = $+{offset};
        next;
      }
    }

    # skip all types that aren't functions, or weren't already handled as
    # the special _START_ OBJT symbol above
    next if ($+{type} eq "OBJT");

    $val = [ $+{offset}, $+{size}, $+{funcname} ];

    push @$symtab_aref, $val;
    if (($symcount++ % 1000) == 0) {
      say "$exec_or_lib_path: PARSED $symcount SYMBOLS";
    }
  }
  # ASSERT that $_start_offset is defined
  assert_defined_variable($_start_offset);

  if ($_start_offset == 0) {
    say "NO NEED TO ADJUST OFFSETS FOR SYMBOLS IN: $exec_or_lib_path";
  } else {
    say "ADJUSTING OFFSETS FOR SYMBOLS IN: $exec_or_lib_path, BY $_start_offset";
    foreach my $symval (@$symtab_aref) {
      $symval->[0] -= $_start_offset;
    }
  }
  # Sort the symbol table by starting address before returning it
  say "SORTING SYMBOL TABLE: $exec_or_lib_path";
  my (@sorted_symtab) = sort {$a->[0] <=> $b->[0] } @$symtab_aref;

  # TODO: Add to cache with:
  #       KEY: { exec_or_lib_path => $exec_or_lib_path, sha1 => $exec_or_lib_sha1 }

  say "RETURNING SORTED SYMBOL TABLE FOR: $exec_or_lib_path";
  return \@sorted_symtab;
}


=head1 BUILT IN DTrace SCRIPTS

These are private methods, which are used to select what kind of DTrace script t

=method _ustack_dtrace

The most basic DTrace, which shows the following data every second:

=for :list
* Timestamp
* PID
* kernel stack (resolved)
* Unresolved user stack
* Occurrence count for the above tuple for that time interval

The unresolved user stacks will be resolved by this module.

=cut

sub _ustack_dtrace {
  my ($self) = shift;

    my $script = <<'END';
#pragma D option noresolve
#pragma D option quiet
#pragma D option ustackframes=100

profile-197Hz
/ execname == "__EXECNAME__" /
{
  @s[pid,tid,stack(),ustack(__USTACK_FRAMES__)] = count();
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

END

    $script = $self->_replace_DTrace_keywords($script);
    return $script;
}

=method _whatfor_DTrace

This DTrace provides kernel / user stack as a thread goes off CPU (goes to
sleep).

It provides, per second:

=for :list
* Timestamp
* PID
* TID (Thread ID)
* Reason thread went off CPU
* kernel stack (resolved) as thread went off CPU
* Unresolved user stack as thread went off CPU
* Quantized histogram indicating how long the thread stayed off CPU

=cut

my _whatfor_DTrace {
  my ($self, $script) = @_;

  my $script = <<'WHATFOR_END';
#pragma D option noresolve
#pragma D option quiet
#pragma D option ustackframes=100

sched:::off-cpu
/ execname == "__EXECNAME__" &&
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
/ execname == "__EXECNAME__" &&
  curlwpsinfo &&
  curlwpsinfo->pr_state == SRUN /
{
  self->bedtime = timestamp;
}

sched:::on-cpu
/self->bedtime && !self->sobj/
{
  @["preempted",pid,tid] = quantize(timestamp - self->bedtime);
  @sdata[pid,tid,stack(),ustack(__USTACK_FRAMES__)] = count();
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
    pid,tid] = quantize(timestamp - self->bedtime);
  @sdata[pid,tid,stack(),ustack(__USTACK_FRAMES__)] = count();

  self->sobj = 0; 
  self->bedtime = 0; 
}

tick-1sec
{
  printf("\n%Y\n",walltimestamp);

  printf("%-32s %5s %-3s %-12s\n","SOBJ OR PREEMPTED","PID","TID","LATENCY(ns)");
  printa("%-32s %5d %-3d %-@12u\n",@);

  trunc(@sdata,32);
  /* printa("PID:%-5d %-3d %k %k %@12u\n",@sdata); */
  printa("%5d %-3d %k %k %@12u\n",@sdata);

  trunc(@);
  trunc(@sdata);
}

WHATFOR_END

    $script = $self->_replace_DTrace_keywords($script);
    return $script;
}



=method _replace_DTrace_keywords

This method takes a DTrace script, and replaces the keywords we recognize.

=cut

sub _replace_DTrace_keywords {
  my ($self,$script) = @_;

  my ($execname,$ustack_frames) =
   ($self->execname, $self->user_stack_frames);

  $script =~ s/__EXECNAME__/$execname/gsmx;
  $script =~ s/__USTACK_FRAMES__/$ustack_frames/gsmx;

  return $script;
}

1;

