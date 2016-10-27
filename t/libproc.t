use strict;
use warnings;

use Test::More;

BEGIN { use_ok('DTrace::UStackResolve::libproc'); }

my $aref = DTrace::UStackResolve::libproc::extract_symtab("/bin/ls");

is_deeply( $aref, [], 'extract_symtab returns an aref' );

done_testing();

