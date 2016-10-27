use strict;
use warnings;

use Test::More;

BEGIN { use_ok('DTrace::UStackResolve'); }

my $aref = DTrace::UStackResolve::extract_symtab("/bin/ls");

is_deeply( $aref, [], 'extract_symtab returns an aref' );

done_testing();

