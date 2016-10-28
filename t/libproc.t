use strict;
use warnings;

use Test::Most;
use Data::Dumper;

BEGIN { use_ok('DTrace::UStackResolve'); }

#my $aref = DTrace::UStackResolve::extract_symtab("/usr/bin/sh");
my $aref = DTrace::UStackResolve::extract_symtab("/usr/lib/librmapi.so");

isa_ok( $aref, 'ARRAY', 'extract_symtab returns an aref' );

cmp_deeply( $aref, array_each(isa("Hash")) );

#print Dumper( $aref );

done_testing();

