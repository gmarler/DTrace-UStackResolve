package DTrace::UStackResolve;

use strict;
use warnings;

use Moose;
use namespace::autoclean;
use IO::Async;
use Future;

# VERSION
#
# ABSTRACT: Resolve User Stacks from DTrace for Large Binaries

=head1

With larger binaries, it's often the case that using DTrace's ustack() call will
take very long amounts of time to complete the symbol table lookups - often long
enough to make DTrace abort because it appears "unresponsive".

With the advent of this DTrace pragma:

#pragma D option noresolve

The output of ustack() will be unresolved, for resolution later.

The purpose of this module is to perform that resolution.

=cut

=head1 ATTRIBUTES

=cut


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


=method 



1;
