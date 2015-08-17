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

has 'symbol_table_cache' => (
  is          => 'ro',
  builder     => '_build_symbol_table_cache',
  lazy        => 1,
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

1;

