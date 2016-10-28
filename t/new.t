use strict;
use warnings;

use Test::Most;
use Data::Dumper;

use_ok('DTrace::UStackResolve');

my $pid = $$;

my $obj = DTrace::UStackResolve->new( { pids => $pid } );

isa_ok($obj, 'DTrace::UStackResolve', 'object is the right type');

done_testing();

