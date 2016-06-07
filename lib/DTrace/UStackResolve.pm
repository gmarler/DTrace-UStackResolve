package DTrace::UStackResolve;

use v5.22.0;
use strict;
use warnings;

use Moose;
use Moose::Util::TypeConstraints;
use MooseX::ClassAttribute;
use MooseX::Log::Log4perl;
use namespace::autoclean;
use File::Basename;
use File::stat;
use FindBin               qw( $Bin );
use IO::File;
use IO::Async;
use IO::Async::Loop;
use IO::Async::FileStream;
use IO::Async::Function;
use IO::Async::Process;
use Future;
use Future::Utils         qw( fmap );
use List::Util            qw( first );
use List::MoreUtils       qw( uniq );
use CHI;
use Digest::SHA1          qw( );
use Tree::RB              qw( LULTEQ );
use IPC::System::Simple   qw( capture $EXITVAL EXIT_ANY );
use Carp;
# Needs Exporter::ConditionalSubs
use Assert::Conditional  qw( :scalar );
use Data::Dumper;


our %dtrace_types = (
  "profile"         => "profile_pid.d",
  "profile_tid"     => "profile_pid_tid.d",
  "whatfor"         => "whatfor_pid.d",
  "whatfor_tid"     => "whatfor_pid_tid.d",
);

#
# TODO: This module assumes use of a Perl with 64-bit ints.  Check for this, or
#       use Math::BigInt if it's missing.
#

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

# Local Type Constraints

subtype 'UStackDepthRange',
  as 'Int',
  where { $_ >= 1 && $_ <= 100 };

# Class Attribute Constants
class_has 'PMAP' => (
  init_arg    => undef,
  is          => 'ro',
  isa         => 'Str',
  default     => "/bin/pmap",
);

class_has 'NM' => (
  init_arg    => undef,
  is          => 'ro',
  isa         => 'Str',
  default     => "/usr/ccs/bin/nm",
);

class_has 'PGREP' => (
  init_arg    => undef,
  is          => 'ro',
  isa         => 'Str',
  default     => "/bin/pgrep",
);

class_has 'DTRACE' => (
  init_arg    => undef,
  is          => 'ro',
  isa         => 'Str',
  default     => "/sbin/dtrace",
);

# Real Attributes
has 'loop' => (
  is          => 'ro',
  isa         => 'IO::Async::Loop',
  builder     => '_build_loop',
  lazy        => 1,
);

=method new()

The constructor takes the following attributes:

=for :list
* execname or pid:         Full path to executable you want to get user stacks
                           for, OR, the PID of interest.
                           One is required, there is no default.

* type:                    The type of DTrace to run, from this list:
                           profile
                           off-cpu

* user_stack_frames:       The depth of the user stacks you want to receive
                           in the output.
                           Default: 100

* autoflush_dtrace_output: Whether to autoflush the DTrace output.
                           Defaults to 0 (false).  Good to enable for
                           scripts you expect slow/intermittent output from.

=cut

has 'execname' => (
  # NOTE: this will be an absolute path to the execname
  is          => 'ro',
  isa         => 'Str',
  #builder     => '_build_execname',
  required    => 1,
);

# NOTE: The name DTrace puts in the ustack to identify the binary itself; often
#       is the name it was invoked with rather than it's real, true name
has 'personal_execname' => (
  # This will be a basename
  is          => 'ro',
  isa         => 'Maybe[Str]',
  lazy        => 1,
  default     => undef,
);


has 'pid'      => (
  is          => 'ro',
  isa         => 'Int',
);

# Normally only set if profile is one that requires a tid
has 'tid'      => (
  # TODO: Unless the appropriate 'type' is specified (requiring a tid), just
  # note that the tid isn't being honored.
  is          => 'ro',
  isa         => 'Maybe[Int]',
  default     => undef,
);

has 'type'     => (
  is          => 'ro',
  isa         => 'Str',
  # TODO: Add a constraint to the available scripts
  default     => 'profile',
);

sub _sanity_check_type {
  my ($self) = @_;

  confess "Invalid DTrace type specified: " . $self->type
    unless (exists($dtrace_types{$self->type}));
}


# TODO: Add a test for constructor called with execname only and pid only
override BUILDARGS => sub {
  my $class = shift;

  if (exists($_[0]->{pid})) {
    # NOTE: The true absolute path to the executable is contained in procfs;
    #       however, the name the process knows itself as, and which it will
    #       report itself as in ustack before a colon is only visible via pargs,
    #       so we probably need to store both
    my $pid = $_[0]->{pid};
    my $a_out = "/proc/$pid/path/a.out";
    my ($abs_path) = readlink($a_out);
    if (not defined($abs_path)) {
      carp "could not open $a_out: $!";
    } else {
      $_[0]->{execname} = $abs_path;
    }

    my $pargs_out = capture( "/bin/pargs $pid" );
    say "PARGS OUT: $pargs_out";
    $pargs_out =~ m/^argv\[0\]:\s+(?<personal_execname>[^\n]+)/gsmx;
    my $personal_execname = $+{personal_execname};
    # NOTE: Storing the basename only
    $_[0]->{personal_execname} = basename($personal_execname);
  }

  return super;
};

#
# OUTPUT FILE NAMES
#
# DTrace script output with unresolved stacks
has 'dscript_unresolved_out' => (
  is          => 'rw',
  isa         => 'Str',
  #builder     => '_build_dscript_unresolved_out',
  default     => "/tmp/dscript.out",
);

# DTrace script Error output
has 'dscript_err' => (
  is          => 'rw',
  isa         => 'Str',
  #builder     => '_build_dscript_err',
  default     => "/tmp/dscript.err",
);

# DTrace output with resolved ustacks
# NOTE: dependent on the exec_basename already being set
has 'resolved_out' => (
  is          => 'rw',
  isa         => 'Str',
  lazy        => 1,
  builder     => '_build_resolved_out',
);

sub _build_resolved_out {
  my ($self) = shift;

  return "/tmp/dtrace.resolved";
}

#
# OUTPUT FILE HANDLES for above
#
has 'dscript_unresolved_out_fh' => (
  is          => 'rw',
  isa         => 'IO::File',
  lazy        => 1,
  default     =>
    sub {
      my ($self) = shift;

      my $file = $self->dscript_unresolved_out;
      unless ($file) {
        confess "DTrace Unresolved Stack File Undefined!";
      }

      my $fh = IO::File->new( $file, ">" );
      confess "Unable to open " . $file . "$!"
        unless ($fh);
      return $fh;
    },
);


# The start time(s) of the execname we started this up
# for.  The point of this is to detect when the value increases,
# indicating that we need to recalculate the:
# - symbol cache
# - Red-Black or AA symbol lookup tree
# - direct lookup cache
# TODO: A check for this should be done whenever a new PID is detected
#       in the DTrace output
has 'pid_starttime' => (
  is          => 'rw',
  isa         => 'HashRef[Int]',
  builder     => '_build_pid_starttime',
  lazy        => 1,
);

sub _build_pid_starttime {
  my ($self) = shift;

  my %start_times =
    map { $_ => $self->_get_pid_start_epoch($_); } @{$self->pids};
  return \%start_times;
}

has 'pids' => (
  is          => 'rw',
  isa         => 'ArrayRef[Int]',
  builder     => '_build_pids',
  lazy        => 1,
);

has 'dynamic_library_paths' => (
  init_arg    => undef,   # don't allow specifying in the constructor
  is          => 'rw',
  isa         => 'ArrayRef[Str]',
  builder     => '_build_dynamic_library_paths',
  lazy        => 1,
  clearer     => '_clear_dynamic_library_paths',
  predicate   => '_has_dynamic_library_paths',
);

sub _build_dynamic_library_paths {
  my ($self) = shift;
  my $pid_starttime_href = $self->pid_starttime;
  my $pmap_func          = $self->pmap_func;

  my $file_paths_f = fmap {
    my ($aref) = @_;
    my ($pid, $start_epoch) = @$aref;
    say "Obtaining list of dynamic libs for PID $pid";
    Future->done( $pmap_func->call( args => [ $pid, $start_epoch ] )->get );
  } foreach => [ map { [ $_, $pid_starttime_href->{$_} ] } keys %{$pid_starttime_href} ],
    concurrent => 8;

  my @file_paths = $file_paths_f->get;

  my @absolute_file_paths =
    uniq
    map { @$_ } @file_paths;

  say Dumper( \@file_paths );
  say Dumper( \@absolute_file_paths );
  return \@absolute_file_paths;
}

has 'symbol_table' => (
  init_arg    => undef,   # don't allow specifying in the constructor
  is          => 'rw',
  isa         => 'HashRef[Str]',
  builder     => '_build_symbol_table',
  lazy        => 1,
  clearer     => '_clear_symbol_table',
  predicate   => '_has_symbol_table',
);

#
# This should get built at the end of building/loading the symbol_table_cache
#
has 'direct_lookup_cache' => (
  init_arg    => undef,   # don't allow specifying in the constructor
  is          => 'rw',
  isa         => 'HashRef[Tree::RB]',
  default     => sub { return { }; },
  lazy        => 1,
);

has 'direct_symbol_cache' => (
  init_arg    => undef,   # don't allow specifying in the constructor
  is          => 'ro',
  isa         => 'CHI',
  builder     => '_build_direct_symbol_cache',
  lazy        => 1,
);


has 'symbol_table_cache' => (
  init_arg    => undef,   # don't allow specifying in the constructor
  is          => 'ro',
  isa         => 'CHI',
  builder     => '_build_symbol_table_cache',
  lazy        => 1,
);

#
# Allow user stack frame depth to be chosen, but default to 100, since
# it's very likely we'll want the full user stack most of the time.
#
has 'user_stack_frames' => (
  is          => 'ro',
  isa         => 'UStackDepthRange',
  default     => 100,
);

has 'autoflush_dtrace_output' => (
  is          => 'ro',
  isa         => 'Num',
  default     => 0,
);

# TODO ATTRIBUTES:
# - autoflush of resolved stack output - to be used for scripts that produce
#   output slowly

sub _build_symbol_table_cache {
  my ($self) = shift;

  # TODO: Allow constructor to pass in a directory to hold the caches
  CHI->new(
            driver       => 'BerkeleyDB',
            cache_size   => '1024m',
            #root_dir     => '/bb/pm/data/symbol_tables',
            root_dir     => '/tmp/symbol_tables',
            namespace    => 'symbol_tables',
            global       => 0,
            on_get_error => 'warn',
            on_set_error => 'warn',
            l1_cache => { driver => 'RawMemory', global => 0, max_size => 64*1024*1024 }
           );
}

sub _build_direct_symbol_cache {
  my ($self) = shift;

  # TODO: Allow constructor to pass in a directory to hold the caches
  CHI->new(
            driver       => 'BerkeleyDB',
            cache_size   => '1024m',
            #root_dir     => '/bb/pm/data/symbol_tables',
            root_dir     => '/tmp/symbol_tables',
            namespace    => 'direct_symbol',
            global       => 0,
            on_get_error => 'warn',
            on_set_error => 'warn',
            l1_cache => { driver => 'RawMemory', global => 0, max_size => 128*1024*1024 }
           );
}

#
# This is where we define the order of attribute definition
#
sub BUILD {
  my ($self) = shift;

  #say "Building D Script Unresolved Output Filename: " .
  #  $self->dscript_unresolved_out;
  $self->dscript_unresolved_out_fh;
  $self->_sanity_check_type;
  $self->pmap_func;
  $self->sha1_func;
  $self->gen_symtab_func;
  $self->loop;
  $self->pids;
  $self->pid_starttime;
  $self->dynamic_library_paths;
  # TODO:
  # - Get the basename of the execname
  $self->personal_execname;
  # - Define the filename for the resolved ustacks to be written to
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

has sha1_func => (
  is      => 'ro',
  isa     => 'IO::Async::Function',
  default => sub {
    return IO::Async::Function->new(
      code        => \&_file_sha1_digest,
    ),
  },
  lazy    => 1,
);

has pmap_func => (
  is      => 'ro',
  isa     => 'IO::Async::Function',
  default => sub {
    return IO::Async::Function->new(
      code        => \&_pid_dynamic_library_paths,
    ),
  },
  lazy    => 1,
);

has gen_symtab_func => (
  is      => 'ro',
  isa     => 'IO::Async::Function',
  default => sub {
    return IO::Async::Function->new(
      code        => \&_gen_symbol_table,
    ),
  },
  lazy    => 1,
);

sub _build_loop {
  my ($self) = shift;

  my $loop = IO::Async::Loop->new;

  my $sha1_func       = $self->sha1_func;
  my $pmap_func       = $self->pmap_func;
  my $gen_symtab_func = $self->gen_symtab_func;

  $loop->add( $sha1_func );
  $loop->add( $pmap_func );
  $loop->add( $gen_symtab_func );

  return $loop;
}

sub _build_pids {
  my ($self) = shift;


  # If our PID is already explicitly set, no need to look further.
  #
  if ($self->pid) {
    return [ $self->pid ];
  }

  my (@pids);
  my ($PGREP) = $self->PGREP;
  my $execname = $self->execname;
  # NOTE: On Solaris, if on global zone, pgrep will pick up the pid with this
  #       execname in ALL zones unless you explicitly ask for the zone *you are
  #       in*
  my $zonename = capture( EXIT_ANY, "/bin/zonename" );
  chomp($zonename);
  my @output = capture( EXIT_ANY, "$PGREP -z $zonename -lxf '^$execname(.+)?'" );

  if ($EXITVAL == 1) {
    carp "No PIDs were found that match [$execname] !";
    # TODO: should this croak or what?
  } elsif ($EXITVAL == 0) {

      chomp(@output);

    say "PIDS:";
    say join("\n",@output);
    @pids = map { my $line = $_;
                  $line =~ m/^(?:\s+)?(?<pid>\d+)\s+/;
                  $+{pid}; } @output;
  } else {
    confess "pgrep returned $EXITVAL, which is a fatal exception for us";
  }

  return \@pids;
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

  my ($symbol_table_cache)  = $self->$symbol_table_cache;
  my (@absolute_file_paths) = $self->dynamic_library_paths;
  my ($gen_symtab_func)     = $self->gen_symtab_func;

  # Look for the symbol tables missing from the cache
  my @missing_symtab_cache_items =
    grep { not defined($symbol_table_cache->get(basename($_))); }
    $execpath,         # Don't forget to add the executable path itself
    @absolute_file_paths;

  # Create the missing cache items
  my $symtabs_f = fmap {
    my ($absolute_path) = shift;
    say "Creating symbol table for $absolute_path";
    Future->done(
        $absolute_path => $gen_symtab_func->call( args => [ $absolute_path ] )->get
    );
  } foreach => [
                 @missing_symtab_cache_items
               ], concurrent => 2;

  my %symtabs = $symtabs_f->get;

  say "SYMBOL TABLE KEYS:";
  foreach my $symtab_path (keys %symtabs) {
    # if (basename($symtab_path) eq "libperl.so.5.22.0") {
    #   say Dumper($symtabs{$symtab_path});
    # }
    unless (defined($symbol_table_cache
                    ->set(basename($symtab_path),
                          $symtabs{$symtab_path}, '7 days'))) {
      say "FAILED to store KEY basename($symtab_path) in CACHE!"
    }
  }

  say "SYMBOL TABLE KEYS IN CACHE:";
  say join("\n", $symbol_table_cache->get_keys);

  return \%symtabs;
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

sub _whatfor_DTrace {
  my ($self) = @_;

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
  my ($pid, $tid) =
    ($self->pid, $self->tid);

  $script =~ s/__EXECNAME__/$execname/gsmx;
  $script =~ s/__USTACK_FRAMES__/$ustack_frames/gsmx;
  if ($pid) {
    $script =~ s/__PID__/$pid/gsmx;
  }
  if ($tid) {
    $script =~ s/__TID__/$tid/gsmx;
  }

  return $script;
}

=method _start_dtrace_capture

This private method starts the DTrace script that has been chosen, and streams
the unresolved output to a file.

=cut

sub _start_dtrace_capture {
  my ($self) = shift;

  my ($execname) = $self->execname;
  my ($DTRACE)   = $self->DTRACE;
  my ($loop)     = $self->loop;

  my ($script) = build_dtrace_script($execname);
  my ($dscript_fh) = build_dtrace_script_fh( $script );
  my ($dscript_filename) = $dscript_fh->filename;

  my $cmd = "$DTRACE -s $dscript_filename";

  say "Going to execute: $cmd";

  my $dscript_output_fh = IO::File->new("/bb/pm/data/dscript.out", ">")
    or confess "Unable to open /bb/pm/data/dscript.out for writing: $!";;
  my $dscript_stderr_fh = IO::File->new("/bb/pm/data/dscript.err", ">")
    or confess "Unable to open /bb/pm/data/dscript.err for writing: $!";;

  my $dtrace_process =
    IO::Async::Process->new(
      command => $cmd,
      stdout  => {
        on_read => sub {
          my ( $stream, $buffref ) = @_;
          #while ( $$buffref =~ s/^(.*)\n// ) {
          while ( length( $$buffref ) ) {
            my $data = substr($$buffref,0, 1024*1024 ,'');
            $dscript_output_fh->print( $data );
          }

          return 0;
        },
      },
      stderr  => {
        on_read => sub {
          my ( $stream, $buffref ) = @_;
          while ( $$buffref =~ s/^(.*)\n// ) {
            $dscript_stderr_fh->print( $1 . "\n" );
          }

          return 0;
        },
      },
      on_finish => sub {
        my ($proc_obj,$exitcode) = @_;
        say "DTrace SCRIPT TERMINATED WITH EXIT CODE: $exitcode!";
        $dscript_output_fh->close;
        $loop->stop;
        exit(1);
      },
      # on_exception => sub {
      #   $dscript_output_fh->close;
      #   say "DTrace Script ABORTED!";
      #   $loop->stop;
      #   exit(1);
      # },
    );

  $loop->add( $dtrace_process );
}

=method _resolve_symbol

Given a line of output, resolve any symbol needing it.

If the symbol cannot be resolved, annotate the line accordingly.

If there is no symbol to be resolve, return the line unchanged.

=cut

sub _resolve_symbol {
  my ($self,$line,$pid) = @_;

  my $direct_symbol_cache = $self->direct_symbol_cache;

  my ($symtab);
  my (%symtab_trees) = %{$self->direct_lookup_cache};

  my $unresolved_re =
    qr/^(?<keyfile>[^:]+):0x(?<offset>[\da-fA-F]+)/;

  if ($line =~ m/^(?<keyfile>[^:]+):0x(?<offset>[\da-fA-F]+)$/) {
    # Return direct lookup if available
    if (my ($result) = $direct_symbol_cache->get($line)) {
      return $result if defined($result);
    }
    my ($keyfile, $offset) = ($+{keyfile}, hex( $+{offset} ) );
    #
    # TODO: Use the PID to lookup the correct symbol table entries
    #       in the symbol_table cache namespace
    # NOTE: This may no longer be necessary, actually, except for
    #       the executable itself.
    #
    ###   if (defined( $symtab = $symbol_table_cache->get($keyfile) )) {
    ###     my $dec_offset = Math::BigInt->from_hex($offset);
    ###     my $index = _binarySearch($dec_offset,$symtab);
    ###     # NOTE: Use defined($index) because the $index can validly be '0'
    ###     if (defined($index)) {
    ###       my ($symtab_entry) = $symtab->[$index];
    ###       # If we actually found the proper symbol table entry, make a pretty output
    ###       # in the stack for it
    ###       if ($symtab_entry) {
    ###         my $funcname = $symtab_entry->[2];
    ###         # my $funcsize = $symtab_entry->[1];
    ###         # say "FUNCNAME: $funcname";
    ###         my $resolved =
    ###           sprintf("%s+0x%x",
    ###                   $funcname,
    ###                   $dec_offset - Math::BigInt->new($symtab_entry->[0]));
    ###         # If we got here, we have something to store in the direct symbol
    ###         # lookup cache
    ###         $direct_symbol_cache->set($line,$resolved,'7 days');
    ###         $line =~ s/^(?<keyfile>[^:]+):0x(?<offset>[\da-fA-F]+)$/${resolved}/;
    ###       } else {
    ###         die "WHAT THE HECK HAPPENED???";
    ###       }
    ###     } else {
    ###       $line .= " [SYMBOL TABLE LOOKUP FAILED]";
    ###     }
    ###     #say "symtab lookup successful";
    if ( defined( my $search_tree = $symtab_trees{$keyfile} ) ) {
      my $symtab_entry = $search_tree->lookup( $offset, LULTEQ );
      if (defined($symtab_entry)) {
        if (($offset >= $symtab_entry->[0] ) and
            ($offset <= ($symtab_entry->[0] + $symtab_entry->[1]) ) ) {
          my $resolved =
            sprintf("%s+0x%x",
                    $symtab_entry->[2],
                    $offset - $symtab_entry->[0]);
          # If we got here, we have something to store in the direct symbol
          # lookup cache
          $direct_symbol_cache->set($line,$resolved,'7 days');
          $line =~ s/^(?<keyfile>[^:]+):0x(?<offset>[\da-fA-F]+)$/${resolved}/;
        } else {
          $line .= " [SYMBOL TABLE LOOKUP FAILED]";
        }
      } else {
        confess "WHAT THE HECK HAPPENED???";
      }
    } else {
      $line .= " [NO SYMBOL TABLE FOR $keyfile]";
    }
    return $line;
  } else {
    return $line;
  }
}

=method start_stack-resolve

Starts up the asynchronous reading of the output of the DTrace script, and the
resolution of the user stack contained therein, and the output of this onto
STDOUT.

=cut

sub start_stack_resolve {
  my ($self) = shift;

  my ($dtrace_outfile) = $self->dtrace_output_file;
  my ($exec_basename)  = basename($self->execname);
  my ($loop)           = $self->loop;

  my $dtrace_output_fh  = IO::File->new($dtrace_outfile, "<");
  my $resolved_fh       = IO::File->new;
  $resolved_fh->fdopen(fileno(STDOUT),"w");

  # TODO: May want to think about changing this from a FileStream to just a
  #       Stream.  Keeping the FileStream for the present just for ease of
  #       debugging in the case where a stack resolution fails.
  my $filestream = IO::Async::FileStream->new(
    read_handle => $dtrace_output_fh,
    autoflush   => $self->autoflush_dtrace_output,
    #on_initial => sub {
    #  my ( $self ) = @_;
    #  #$self->seek_to_last( "\n" );
    #  # Start at beginning of file
    #  $self->seek( 0 );
    #},

    on_read => sub {
      my ( $self, $buffref ) = @_;
      # as we read the file to resolve symbols in, we often need to know
      # what the current PID is for the data which follows to do an accurate
      # symbol table lookup
      my ($current_pid);

      while( $$buffref =~ s/^(.*)\n// ) {
        my $line = $1;
        #say "Received a line $line";

        if ($line =~ m/^PID:(?<pid>\d+)/) {
          $current_pid = $+{pid};
          # TODO: look this PID's entries up in at least the following
          #       namespaces, generating them asynchronously if necessary:
          # - ustack_resolve_pids
          # - symbol_table
          $resolved_fh->print( "$line\n" );
          next;
        }
        $line = resolve_symbols( $line, $current_pid );
        $resolved_fh->print( "$line\n" );
      }

      return 0;
    },
  );

  $loop->add( $filestream );
}

#
# UTILITY FUNCTIONS - NOT to be called as object methods, but as Future loops
#
sub _pid_dynamic_library_paths {
  my ($pid) = shift;

  # NOTE: It's likely we don't need to bother caching this, as it's really
  #       quick.
  # TODO: Check whether this has already been stored for this PID instance, using
  #       KEY: { pid => $pid, start_epoch => $start_epoch }
  #       Return immediately if available
  my @pids = ( $pid );
  my $PMAP = __PACKAGE__->PMAP;
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

sub _get_pid_start_epoch {
  my ($self,$pid) = @_;

  my ($st);

  unless ($st = stat("/proc/$pid")) {
    carp "PID file /proc/$pid missing: $!";
    return;
  }
  return $st->ctime;
}

sub _file_sha1_digest {
  my ($self,$file) = @_;

  my $fh   = IO::File->new($file,"<");
  unless (defined $fh) {
    carp "$file does not exist: $!";
    return;
  }
  my $sha1 = Digest::SHA1->new;

  $sha1->addfile($fh);
  my $digest = $sha1->hexdigest;
  say "SHA-1 of $file is: $digest";
  return $digest;
}

sub _gen_symbol_table {
  # Given a path to a dynamic/shared library or an executable,
  # generate the symbol table.
  # The #pragma for noresolve ensures each generated symbol will be of the
  # form <entity>:<offset from base of entity>
  #
  # This means that we can use the symbol table with base address assumed to be
  # implicitly 0 to resolve symbols without further work.
  #
  my ($self, $exec_or_lib_path, $exec_or_lib_sha1) = @_;
  # $start_offset is the offset of the _START_ symbol in a library or exec
  my ($symtab_aref,$symcount,$_start_offset);

  # TODO: Check whether data is in cache; return immediately if it is

  say "Building symtab for $exec_or_lib_path";
  my ($NM) = $self->NM;
  # TODO: Convert to IO::Async::Process
  my $out       = capture( "$NM -C -t d $exec_or_lib_path" );

  say "CAPTURED " . length($out) . " BYTES OF OUTPUT FROM nm OF $exec_or_lib_path";

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
    if (($symcount++ % 10000) == 0) {
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

1;
