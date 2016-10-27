use strict;
use warnings;

use Test::More;

BEGIN { use_ok('DTrace::UStackResolve::LibProc'); }

my $aref = DTrace::UStackResolve::LibProc::extract_symtab("/bin/ls");

is_deeply( $aref, [], 'extract_symtab returns an aref' );

done_testing();

