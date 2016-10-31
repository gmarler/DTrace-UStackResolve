package DTrace::UStackResolve;

use v5.22.0;
use strict;
use warnings;

use Moose;
use Moose::Util::TypeConstraints;
use MooseX::ClassAttribute;
use MooseX::Log::Log4perl;
use namespace::autoclean;
use File::Basename        qw( basename );
use File::stat;
use File::ShareDir        qw( :ALL );
use File::Temp            qw();
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
use Socket                qw(SOL_SOCKET SO_RCVBUF SO_SNDBUF);
use Config;
use Data::Dumper;


our %dtrace_types = (
  "profile"         => "profile_pid.d",
  "profile_tid"     => "profile_pid_tid.d",
  "off-cpu"         => "whatfor_pid.d",
  "off-cpu_tid"     => "whatfor_pid_tid.d",
);

#
# TODO: This module assumes use of a Perl with 64-bit ints.  Check for this, or
#       use Math::BigInt if it's missing.
#

# VERSION
#
# ABSTRACT: Resolve User Stacks from DTrace for Large Binaries

require XSLoader;

XSLoader::load('DTrace::UStackResolve', $VERSION);

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

subtype 'CHI',
  as 'Object',
  where { blessed($_) =~ /^CHI::/ };

# Class Attribute Constants
class_has 'LDD' => (
  init_arg    => undef,
  is          => 'ro',
  isa         => 'Str',
  default     => "/bin/ldd",
);

class_has 'PLDD' => (
  init_arg    => undef,
  is          => 'ro',
  isa         => 'Str',
  default     => "/bin/pldd",
);

class_has 'PGREP' => (
  init_arg    => undef,
  is          => 'ro',
  isa         => 'Str',
  default     => "/bin/pgrep",
);

class_has 'ELFDUMP' => (
  init_arg    => undef,
  is          => 'ro',
  isa         => 'Str',
  default     => "/usr/bin/elfdump",
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
  predicate   => '_has_loop',
  lazy        => 1,
);

#
# Will be passed a list of PIDs or a list of binaries
# PIDs (live processes) and executables (a.outs) must be handled differently
#
# - A live process will immediately get all of the dynamic objects and their
#   symbols
#
# - Reading the symbol table from an a.out will only show the a.out object's
#   personal symbol table.  You must manually use ldd to extract all the
#   library names and then extract those symbol tables independently.
#

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
  #required    => 1,
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
  lazy        => 1,
);

sub _sanity_check_type {
  my ($self) = @_;

  confess "Invalid DTrace type specified: " . $self->type
    unless (exists($dtrace_types{$self->type}));
}

# Flag to know when DTrace has exited, so we can know that the unresolved output
# file will no longer grow, and we can stop working when we reach the end of
# that file
has 'dtrace_has_exited' => (
  is          => 'rw',
  isa         => 'Bool',
  default     => 0,
);

#
# INPUT FILE ATTRIBUTES
#
# The contents of the DTrace template we will use
has 'dtrace_template_contents' => (
  is          => 'ro',
  isa         => 'Str',
  builder     => '_build_dtrace_template_contents',
  lazy        => 1,
);

# The contents of the DTrace script after the template has had it's keywords
# resolved
has 'dtrace_script_contents' => (
  is          => 'ro',
  isa         => 'Str',
  builder     => '_build_dtrace_script_contents',
  lazy        => 1,
);

# The filehandle for the temporary file that contains the DTrace script we've
# build from a template - DTrace will be handed the filename of this file to
# generate the unresolved output
has 'dtrace_script_fh' => (
  is          => 'ro',
  isa         => 'File::Temp',
  builder     => '_build_dtrace_script_fh',
  lazy        => 1,
);

#
# OUTPUT FILE NAMES
#
# DTrace script output with unresolved stacks
has 'dscript_unresolved_out_fh' => (
  is          => 'rw',
  isa         => 'File::Temp',
  #builder     => '_build_dscript_unresolved_out',
  default     =>
    sub {
      my ($self) = shift;
      my ($fh)   = File::Temp->new('DTrace-UNRESOLVED-XXXX',
                                    DIR => '/tmp',
                                    UNLINK => 0,
                                   );
      say "UNRESOLVED USTACK OUTPUT FILE: " . $fh->filename;
      return $fh;
    },
  lazy        => 1,
);

# DTrace script Error output
has 'dscript_err_fh' => (
  is          => 'rw',
  isa         => 'File::Temp',
  #builder     => '_build_dscript_err',
  default     =>
    sub {
      my ($self) = shift;
      my ($fh)   = File::Temp->new('DTrace-UNRESOLVED-ERR-XXXX',
                                    DIR => '/tmp',
                                    UNLINK => 1,
                                   );
      return $fh;
    },
  lazy        => 1,
);

# DTrace output with resolved ustacks
# NOTE: dependent on the exec_basename already being set
has 'resolved_out_fh' => (
  is          => 'ro',
  isa         => 'IO::File',
  lazy        => 1,
  builder     => '_build_resolved_out_fh',
);

sub _build_resolved_out_fh {
  my ($self) = shift;

  # NOTE: Since we can have multiple PIDs, just take the first one
  #       Maybe later we can split these out, if we care, and produce
  #       an array of resolved output files to write into
  my ($pid)            = $self->pids->[0];
  my ($execname)       = $self->personal_execname;
  my ($resolved_fname) = "/tmp/$execname-$pid.RESOLVED";
  my ($resolved_fh)    = IO::File->new("$resolved_fname", ">>") or
    die "Unable to open $resolved_fname for writing";

  say "RESOLVED stacks in: $resolved_fname";
  return $resolved_fh;
}

# TODO: We actually should look at some way to uniquely identify the binary, as
#       that's the only thing whose changing matters.  Perhaps the inode?
#       Anything about the start time is irrelevant, other than knowing if it
#       changed, the on-disk file *might* have changed and should be checked,
#       and the cache possibly regenerated.
#       Also worth noting that any of the dynamic objects changing will also
#       require the cache for that object's file to be udpated
# The start time(s) of the execname we started this up
# for.  The point of this is to detect when the value increases,
# indicating that we need to recalculate the:
# - symbol cache
# - Red-Black or AA symbol lookup tree
# - direct lookup cache
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
  #builder     => '_build_pids',
  #required    => 1,
  #lazy        => 1,
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

=head2  _build_dynamic_library_paths

This function processes the output of the pldd command on each PID of
interest, producing the absolute path of each dynamic library the PID has
loaded.

This is used as the list of libraries from which to extract symbol tables.

ldd on a non-running binary is sadly not sufficient for this, as won't go
through the whole library resolution process, and thus some libraries will be
omitted, as they're not yet known to be needed; so that's out.

=cut

sub _build_dynamic_library_paths {
  my ($self) = shift;
  my $pid_starttime_href = $self->pid_starttime;
  my $pldd_func          = $self->pldd_func;

  my $file_paths_f = fmap {
    my ($aref) = @_;
    my ($pid, $start_epoch) = @$aref;
    say "Obtaining list of dynamic libs for PID $pid";
    Future->done( $pldd_func->call( args => [ $pid, $start_epoch ] )->get );
  } foreach => [ map { [ $_, $pid_starttime_href->{$_} ] } keys %{$pid_starttime_href} ],
    concurrent => 8;

  my @file_paths = $file_paths_f->get;

  # Make sure the list of libraries is composed of unique members
  my @absolute_file_paths =
    uniq
    map { @$_ } @file_paths;

  #say Dumper( \@file_paths );
  say Dumper( \@absolute_file_paths );
  return \@absolute_file_paths;
}

has 'symbol_table' => (
  init_arg    => undef,   # don't allow specifying in the constructor
  is          => 'rw',
  isa         => 'HashRef[ArrayRef]',
  builder     => '_build_symbol_table',
  lazy        => 1,
  clearer     => '_clear_symbol_table',
  predicate   => '_has_symbol_table',
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
# This should get built at the end of building/loading the symbol_table_cache
#
has 'direct_lookup_cache' => (
  init_arg    => undef,   # don't allow specifying in the constructor
  is          => 'rw',
  isa         => 'HashRef[Tree::RB]',
  builder     => '_build_direct_lookup_cache',
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
            l1_cache     => { driver   => 'RawMemory',
                              global   => 0,
                              max_size => 64*1024*1024,
                            }
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
            l1_cache     => { driver   => 'RawMemory',
                              global   => 0,
                              max_size => 128*1024*1024,
                            }
           );
}

sub _build_direct_lookup_cache {
  my ($self) = shift;

  my ($symbol_table_cache) = $self->symbol_table_cache;

  say "CREATING RED-BLACK DIRECT LOOKUP SYMBOL TREE";
  my %symtab_trees;
  foreach my $key ($symbol_table_cache->get_keys) {
    my $symtab_aref = $symbol_table_cache->get($key);
    my $tree = Tree::RB->new();
    foreach my $entry (@$symtab_aref) {
      $tree->put( $entry->{start}, $entry );
    }

    # This key is the absolute path to the item
    $symtab_trees{$key} = $tree;
    my ($basename_key) = basename($key);
    # And this is the "short" key, which will match what DTrace's unresolved
    # address is usually prefixed with
    say "Adding key $basename_key";
    $symtab_trees{$basename_key} = $tree;
  }

  return \%symtab_trees;
}

# TODO: Add a test for constructor called with execname only and pids only
override BUILDARGS => sub {
  my $class = shift;

  if (exists($_[0]->{pids})) {
    # NOTE: The true absolute path to the executable is contained in procfs;
    #       however, the name the process knows itself as, and which it will
    #       report itself as in ustack before a colon is only visible via pargs,
    #       so we probably need to store both
    foreach my $pid (@{$_[0]->{pids}}) {
      my $a_out = "/proc/$pid/path/a.out";
      my ($abs_path) = readlink($a_out);
      if (not defined($abs_path)) {
        carp "could not open $a_out: $!";
      } else {
        $_[0]->{execname} = $abs_path;
      }
      # NOTE: Storing the basename only
      $_[0]->{personal_execname} = basename($abs_path);

      #my $pargs_out = capture( "/bin/pargs $pid" );
      #say "PARGS OUT: $pargs_out";
      #$pargs_out =~ m/^argv\[0\]:\s+(?<personal_execname>[^\n]+)/gsmx;
      #my $personal_execname = $+{personal_execname};
      ## NOTE: Storing the basename only
      #$_[0]->{personal_execname} = basename($personal_execname);
    }
  }

  return super;
};

#
# This is where we define the order of attribute definition
#
sub BUILD {
  my ($self) = shift;

  #say "Building D Script Unresolved Output Filename: " .
  #  $self->dscript_unresolved_out;
  $self->_sanity_check_type;
  # Setup Async functions for later use
  $self->pldd_func;
  $self->sha1_func;
  $self->gen_symtab_func;
  $self->loop;
  # TODO: Cleanup - Doesn't seem to be a builder here anymore
  $self->pids;
  $self->pid_starttime;
  # Actually gather dynamic library paths
  $self->dynamic_library_paths;
  say "GENERATING SYMBOL TABLE";
  $self->symbol_table;
  $self->direct_lookup_cache;
  $self->type;
  $self->dtrace_template_contents;
  say "GENERATE personal execname: " .
    $self->personal_execname;
  $self->dtrace_script_contents;
  $self->dtrace_script_fh;
  $self->dscript_unresolved_out_fh;
  $self->dscript_err_fh;
  $self->resolved_out_fh;
  # TODO:
  # - Define the filename for the resolved ustacks to be written to
  $self->_start_dtrace_capture;
  $self->start_stack_resolve;
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

has pldd_func => (
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
  my $pldd_func       = $self->pldd_func;
  my $gen_symtab_func = $self->gen_symtab_func;

  $loop->add( $sha1_func );
  $loop->add( $pldd_func );
  $loop->add( $gen_symtab_func );

  return $loop;
}

# sub _build_pids {
#   my ($self) = shift;
#
#   my (@pids);
#   my ($PGREP) = $self->PGREP;
#   my $execname = $self->execname;
#   # NOTE: On Solaris, if on global zone, pgrep will pick up the pid with this
#   #       execname in ALL zones unless you explicitly ask for the zone *you are
#   #       in*
#   my $zonename = capture( EXIT_ANY, "/bin/zonename" );
#   chomp($zonename);
#   my @output = capture( EXIT_ANY, "$PGREP -z $zonename -lxf '^$execname(.+)?'" );
#
#   if ($EXITVAL == 1) {
#     carp "No PIDs were found that match [$execname] !";
#     # TODO: should this croak or what?
#   } elsif ($EXITVAL == 0) {
#
#       chomp(@output);
#
#     say "PIDS:";
#     say join("\n",@output);
#     @pids = map { my $line = $_;
#                   $line =~ m/^(?:\s+)?(?<pid>\d+)\s+/;
#                   $+{pid}; } @output;
#   } else {
#     confess "pgrep returned $EXITVAL, which is a fatal exception for us";
#   }
#
#   return \@pids;
# }


# Given a path to a dynamic/shared library or an executable,
# generate the symbol table.
# The #pragma for noresolve ensures each generated symbol will be of the
# form <entity>:<offset from base of entity>
#
# This means that we can use the symbol table with base address assumed to be
# implicitly 0 to resolve symbols without further work.
#

# TODO: Turn this from a normal builder into a Future
# TODO: Change key from basename to absolute path; store basename as another key
#       or find another unique identifier
# TODO: Make sure to do a.out as well as dynamic libs
sub _build_symbol_table {
  my ($self) = shift;

  my ($symbol_table_cache)  = $self->symbol_table_cache;
  my (@absolute_file_paths) = @{$self->dynamic_library_paths};
  my ($gen_symtab_func)     = $self->gen_symtab_func;
  # a.out
  my ($execpath)            = $self->execname;

  # Look for the symbol tables missing from the cache
  my @missing_symtab_cache_items =
    grep { not defined($symbol_table_cache->get($_)); }
    $execpath,         # Don't forget to add the a.out path too
    @absolute_file_paths;

  # Create the missing cache items
  my $symtabs_f = fmap {
    my ($absolute_path) = shift;
    #say "Creating symbol table for $absolute_path";
    # we cannot pass $self across the boundary as args
    Future->done(
        $absolute_path => $gen_symtab_func->call( args => [ $absolute_path ] )->get
    );
  } foreach => [
                 @missing_symtab_cache_items
               ], concurrent => 2;

  my %symtabs = $symtabs_f->get;

  #say "SYMBOL TABLE KEYS:";
  foreach my $symtab_path (keys %symtabs) {
    unless (defined($symbol_table_cache
                    ->set($symtab_path,
                          $symtabs{$symtab_path}, '7 days'))) {
      say "FAILED to store KEY basename($symtab_path) in CACHE!"
    }
  }

  #say "SYMBOL TABLE KEYS IN CACHE:";
  #say join("\n", $symbol_table_cache->get_keys);

  return \%symtabs;
}


=head1 SELECTING TYPE OF DTrace SCRIPT

Specifying the <C>type<C> attribute will allow selection of the kind of DTrace
to script to activate.

=for :list
* profile
  197Hz profile for all threads in a PID
* profile_tid
  197Hz profile for a specific threads in a PID
* whatfor
  Why each thread in a PID goes off CPU
* whatfor_tid
  Why a specific thread in a PID goes off CPU

=cut

=method _build_dtrace_template_contents

Private function that selects the most appropriate DTrace script template from
those available, based on <C>type<C> attribute, among others, and returns it's
raw contents for later processing

=cut

sub _build_dtrace_template_contents {
  my ($self) = shift;

  my ($type) = $self->type;
  say "DTrace Type: $type";
  my $template = $dtrace_types{$type};

  say "DIST FILE:   " . dist_file('DTrace-UStackResolve', $template);
  #say "MODULE FILE: " . module_file(__PACKAGE__, $template);
  #say "CLASS FILE:  " . class_file(__PACKAGE__, $template);
  #say "DIST DIR:    " . dist_dir('DTrace-UStackResolve');
  #say "MODULE DIR:  " . module_dir(__PACKAGE__);
  my ($template_path) = dist_file('DTrace-UStackResolve', $template);
  say "DTrace Template File: $template_path";

  my $fh = IO::File->new($template_path, "<");
  my $c = do { local $/; <$fh>; };

  return $c
}

=method _build_dtrace_script_contents

Private function that takes the DTrace template contents and resolves the
keywords, for later writing to a file.

=cut

sub _build_dtrace_script_contents {
  my ($self) = shift;

  my ($template) = $self->dtrace_template_contents();
  my ($script)   = $self->_replace_DTrace_keywords($template);

  return $script;
}

=method _replace_DTrace_keywords

This method takes a DTrace script, and replaces the keywords we recognize.

=cut

sub _replace_DTrace_keywords {
  my ($self,$script) = @_;

  my ($execname,$ustack_frames) =
    ($self->personal_execname, $self->user_stack_frames);
  my ($pids_aref, $tid) =
    ($self->pids, $self->tid);

  say "REPLACING __EXECNAME__ with $execname";
  say "REPLACING __USTACK_FRAMES__ with $ustack_frames";
  $script =~ s/__EXECNAME__/$execname/gsmx;
  $script =~ s/__USTACK_FRAMES__/$ustack_frames/gsmx;

  my (@pidlist_snippets, $pidlist_snippet);

  foreach my $pid (@$pids_aref) {
    push @pidlist_snippets, " ( pid == $pid ) ";
  }

  $pidlist_snippet = "( \n" . join('||', @pidlist_snippets) . "\n)";

  say "Build __PIDLIST__ replacement:\n$pidlist_snippet";

  $script =~ s/__PIDLIST__/$pidlist_snippet/gsmx;

  if ($tid) {
    say "REPLACING __TID__ with $tid";
    $script =~ s/__TID__/$tid/gsmx;
  }

  return $script;
}

sub _build_dtrace_script_fh {
  my ($self) = shift;

  my ($script_contents) = $self->dtrace_script_contents;
  my ($tfh)             = File::Temp->new( 'DTrace-Script-XXXX',
                                           DIR => '/tmp',
                                           UNLINK => 0,
                                         );

  $tfh->print($script_contents);
  $tfh->flush;

  return $tfh;
}


=method _start_dtrace_capture

This private method starts the DTrace script that has been chosen, and streams
the unresolved output to a file.

=cut

sub _start_dtrace_capture {
  my ($self) = shift;

  my ($DTRACE)   = $self->DTRACE;
  my ($loop)     = $self->loop;

  my ($dscript_fh)        = $self->dtrace_script_fh;
  my ($dscript_filename)  = $dscript_fh->filename;
  my ($unresolved_out_fh) = $self->dscript_unresolved_out_fh;
  my ($stderr_out_fh)     = $self->dscript_err_fh;

  my $cmd = "$DTRACE -s $dscript_filename";

  say "Going to execute: $cmd";

  my $dtrace_process =
    IO::Async::Process->new(
      command => $cmd,
      stdout  => {
        via     => 'socketpair',
        prefork => sub {
          my ($parentfd, $childfd) = @_;

          $parentfd->setsockopt(SOL_SOCKET, SO_RCVBUF, 50*1024*1024);
          $parentfd->setsockopt(SOL_SOCKET, SO_SNDBUF, 50*1024*1024);
          $childfd ->setsockopt(SOL_SOCKET, SO_RCVBUF, 50*1024*1024);
          $childfd ->setsockopt(SOL_SOCKET, SO_SNDBUF, 50*1024*1024);
        },
        on_read => sub {
          my ( $stream, $buffref ) = @_;

          while ( length( $$buffref ) ) {
            my $data = substr($$buffref,0, 5*1024*1024 ,'');
            $unresolved_out_fh->print( $data );
          }

          return 0;
        },
      },
      stderr  => {
        on_read => sub {
          my ( $stream, $buffref ) = @_;
          while ( $$buffref =~ s/^(.*)\n// ) {
            $stderr_out_fh->print( $1 . "\n" );
          }

          return 0;
        },
      },
      on_finish => sub {
        my ($proc_obj,$exitcode) = @_;

        my %sig_num;
        my @sig_name;

        my @names = split ' ', $Config{sig_name};
        @sig_num{@names} = split ' ', $Config{sig_num};
        foreach (@names) {
          $sig_name[$sig_num{$_}] ||= $_;
        }

        my $status = $exitcode >> 8;
        my $signal = $exitcode & 127;
        my $core_produced = $exitcode & 128;
        say "DTrace SCRIPT TERMINATED WITH STATUS: $status";
        if ($signal) {
          say "DTrace SCRIPT TERMINATED BY SIGNAL: ", $sig_name[$signal];
        }
        if ($core_produced) {
          say "DTrace SCRIPT PRODUCED A CORE DUMP";
        }

        $unresolved_out_fh->close;
        # Note that DTrace has stopped.  When end of output file
        # has been reached by resolver, then exit script elsewhere.
        $self->dtrace_has_exited(1);
        $loop->remove( $proc_obj );
        #
        # This is what we used to do:
        # At this point, DTrace has stopped producing output, but we're
        # likely not done resolving it yet - let things run...FOREVER
        #$loop->stop;
        #exit(1);
      },
      # on_exception => sub {
      #   $unresolved_out_fh->close;
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
    
    # NOTE: This is looking things up by the short basename of the library
    if ( defined( my $search_tree = $symtab_trees{$keyfile} ) ) {
      my $symtab_entry = $search_tree->lookup( $offset, LULTEQ );
      if (defined($symtab_entry)) {
        if (($offset >= $symtab_entry->{start} ) and
            ($offset <= ($symtab_entry->{start} + $symtab_entry->{size}) ) ) {
          my $resolved =
            sprintf("%s+0x%x",
                    $symtab_entry->{function},
                    $offset - $symtab_entry->{start});
          # If we got here, we have something to store in the direct symbol
          # lookup cache
          $direct_symbol_cache->set($line,$resolved,'7 days');
          $line =~ s/^(?<keyfile>[^:]+):0x(?<offset>[\da-fA-F]+)$/${resolved}/;
        } else {
          $line .= " [SYMBOL TABLE LOOKUP FAILED]";
        }
      } else {
        say "FAILED TO LOOKUP ENTRY FOR: $keyfile";
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

=method start_stack_resolve

Starts up the asynchronous reading of the output of the DTrace script, and the
resolution of the user stack contained therein, and the output of this onto
STDOUT.

=cut

sub start_stack_resolve {
  my ($self) = shift;

  my ($obj) = $self; # for use in IO::Async::FileStream callback below
  my ($unresolved_out) = $self->dscript_unresolved_out_fh->filename;
  my ($resolved_fh)    = $self->resolved_out_fh;
  my ($loop)           = $self->loop;

  my $dtrace_unresolved_fh  = IO::File->new($unresolved_out, "<");

  # TODO: May want to think about changing this from a FileStream to just a
  #       Stream.  Keeping the FileStream for the present just for ease of
  #       debugging in the case where a stack resolution fails.
  my $filestream = IO::Async::FileStream->new(
    read_handle => $dtrace_unresolved_fh,
    autoflush   => $self->autoflush_dtrace_output,
    #on_initial => sub {
    #  my ( $self ) = @_;
    #  #$self->seek_to_last( "\n" );
    #  # Start at beginning of file
    #  $self->seek( 0 );
    #},

    on_read => sub {
      my ( $self, $buffref, $eof ) = @_;
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
        $line = $obj->_resolve_symbol( $line, $current_pid );
        $resolved_fh->print( "$line\n" );
      }

      # This might not be the cleanest way to go about this...
      if ($eof) {
        if ($obj->dtrace_has_exited) {
          say "DTrace Script has exited, and read everything it produced - EXITING";
          exit(0);
        }
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
  my @pids = ( $pid );
  my $PLDD = __PACKAGE__->PLDD;
  my %libpath_map;

  # Dynamic .so library analysis
  my $pldd_so_regex =
    qr{
       ^ (?<libpath>/[^\n]+?\.so(?:[^\n]+|)) \n # Absolute path only
      }smx;

  foreach my $pid (@pids) {
    my $pldd_output = capture( "$PLDD $pid" );
    while ($pldd_output =~ m{$pldd_so_regex}gsmx) {
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
  # Given a path to an executable, generate the symbol table.
  # The #pragma for noresolve ensures each generated symbol will be of the
  # form <entity>:<offset from base of entity>
  #
  # This means that we can use the symbol table with base address assumed to be
  # implicitly 0 to resolve symbols without further work.
  #
  my ($exec_or_lib_path, $exec_or_lib_sha1) = @_;
  # $start_offset is the offset of the _START_ symbol in a library or exec
  my ($symtab_aref,$symcount,$_start_offset);

  # TODO: Check whether data is in cache; return immediately if it is

  #say "Building symtab for $exec_or_lib_path";

  # TODO: Don't call extract_symtab directly - call it through...
  my $elf_type = __PACKAGE__->_elf_type($exec_or_lib_path);
  if ($elf_type eq "ET_EXEC") {
    #say "$exec_or_lib_path is an a.out (executable)";
    $symtab_aref = __PACKAGE__->_exec_symbol_tuples($exec_or_lib_path);
  } elsif ($elf_type eq "ET_DYN") {
    #say "$exec_or_lib_path is a dynamic library";
    $symtab_aref = __PACKAGE__->_dyn_symbol_tuples($exec_or_lib_path);
  } else {
    say "[$exec_or_lib_path] is ELF Type $elf_type: SKIPPING";
  }

  $symcount = scalar(@$symtab_aref);
  say "$exec_or_lib_path: PARSED TOTAL OF $symcount SYMBOLS";

  # Sort the symbol table by starting address before returning it
  say "SORTING SYMBOL TABLE: $exec_or_lib_path";
  my (@sorted_symtab) = sort {$a->{start} <=> $b->{start} } @$symtab_aref;

  # TODO: Add to cache with:
  #       KEY: { exec_or_lib_path => $exec_or_lib_path, sha1 => $exec_or_lib_sha1 }

  #say "RETURNING SORTED SYMBOL TABLE FOR: $exec_or_lib_path";
  return \@sorted_symtab;
}



# Grab ELF Type:
# - ET_EXEC for a.out
# - ET_DYN  for dynamic library
# Ignore all else
sub _elf_type {
  my ($self, $file) = @_;

  my ($ELFDUMP) = $self->ELFDUMP;
  my $out = capture("$ELFDUMP -e $file");

  #say $out;
  $out =~ m/^ \s+ e_type: \s+ (?<elf_type>[^\n]+)/smx;

  my $elf_type = $+{elf_type};

  #say "[$file] ELF Type: $elf_type";

  return $elf_type;
}

# Get list of symbol tuples from a given file, properly offset
sub _exec_symbol_tuples {
  my ($self, $file) = @_;

  # TODO:
  # If the symbol table file map already contains this file, skip it
  # return if exists($symbols{$file});
  #
  # NOTE: The base address for all a.out's is identical across all instances of
  # the executable running.  Thus, we only need to do this once, and make sure
  # all instances are loaded from the exact same file to know our lookups will
  # always be good.

  # Extract load address from the ELF file
  my $load_address = $self->_get_exec_load_address($file);

  # Extract symbol table
  # TODO: fix extract_symtab so it can accept an object or __PACKAGE__ (class)
  #       name
  my $function_tuples = DTrace::UStackResolve::extract_symtab($file);

  if ($load_address == 0) {
    say "NO NEED TO ADJUST OFFSETS FOR SYMBOLS IN: $file";
  } else {
    say "ADJUSTING SYMBOLS IN: $file, BY LOAD ADDRESS $load_address";
    foreach my $tuple (@$function_tuples) {
      # Only want to do this if the result won't be negative
      if (($tuple->{start} - $load_address) <= 0) {
        say "UNABLE TO ADJUST OFFSET " . $tuple->{start} . " for " . $tuple->{function};
      } else {
        $tuple->{start} -= $load_address;
      }
    }
  }
  return $function_tuples
}

# Get a.out load address
sub _get_exec_load_address {
  my ($self, $file) = @_;

  my ($ELFDUMP) = $self->ELFDUMP;
  my $out = capture("$ELFDUMP -p $file");

  if ($out =~ m/ \s+ p_vaddr: \s+ (?<load_address_in_hex>\S+) \s+ [^\n]+\n
                 [^\n]+ p_type: \s+ \[ \s+ PT_LOAD \s+ \]/smx) {
    # We're all good
  } else {
    # SOMETHING IS WRONG
    say "UNABLE TO FIND FIRST PT_LOAD PROGRAM HEADER";
    return; # undef
  }
  # TODO: Confirm we don't need Math::BigInt here
  #my $load_address = Math::BigInt->new($+{load_address_in_hex});
  my $hex_load_address = $+{load_address_in_hex};
  my $load_address     = hex($hex_load_address);

  say "LOAD ADDRESS (hex): " . $hex_load_address;
  say "LOAD ADDRESS (dec): " . $load_address;
  # ->as_hex() specific to Math::BigInt
  # say "LOAD ADDRESS (hex): " . $load_address->as_hex();
  return $load_address;
}

# Get list of dynamic library symbol tuples
sub _dyn_symbol_tuples {
  my ($self, $file) = @_;

  # TODO:
  # If the symbol table file map already contains this file, skip it
  # return if exists($symbols{$file});

  # NOTE: Load address for dynamic object not needed - DTrace helps us out
  # there in the unresolved ustack() output by prefixing the addresses by the
  # implied base address.  So we don't even have to keep a table of the base
  # addresses of these per PID.  Yahoo!

  # Extract symbol table
  # TODO: fix extract_symtab so it can accept an object or __PACKAGE__ (class)
  #       name
  # At present, we can't do this through libproc (extract_symtab), as it can
  # only operate on executables or entire PIDs.
  # So for the short term, we're using the old nm method.
  #my $function_tuples = DTrace::UStackResolve::extract_symtab($file);

  # TODO: May want to call these in parallel via an IO::Async Function
  my $function_tuples = DTrace::UStackResolve::extract_symtab($file);

  return $function_tuples;
}


1;
