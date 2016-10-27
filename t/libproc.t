use strict;
use warnings;

use Test::More;

BEGIN { use_ok('DTrace::UStackResolve'); }

my $aref = DTrace::UStackResolve::extract_symtab("/bin/ls");

isa_ok( $aref, 'ARRAY', 'extract_symtab returns an aref' );

done_testing();

