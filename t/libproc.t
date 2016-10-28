use strict;
use warnings;

use Test::More;
use Data::Dumper;

BEGIN { use_ok('DTrace::UStackResolve'); }

my $aref = DTrace::UStackResolve::extract_symtab("/usr/bin/sh");

isa_ok( $aref, 'ARRAY', 'extract_symtab returns an aref' );

print Dumper( $aref );

done_testing();

