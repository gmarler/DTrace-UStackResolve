package DTrace::UStackResolve::libproc;

use strict;
use warnings;
use XSLoader;

# VERSION

# ABSTRACT: An interface to Solaris libproc implemented in Perl XS

XSLoader::load('DTrace::UStackResolve::libproc', $VERSION);

1;

__END__

