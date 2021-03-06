use strict;
use warnings;

use v5.22;
use Test::Most;
use File::Temp      qw();
use Data::Dumper;

use_ok('DTrace::UStackResolve');

# Check the default
my $obj = DTrace::UStackResolve->new( { pids => [ $$ ],
                                        runtime => '1sec', } );

cmp_ok( $obj->output_dir, 'eq', "/tmp",
        "Default output dir is /tmp" );

# Check non-existent dir
dies_ok(
  sub {
    my $obj = DTrace::UStackResolve->new( { pids => [ $$ ],
                                            output_dir => '/my/bogus/dir',
                                            runtime    => '1sec',
                                          } );
  },
  'Should die with non-existent output dir'
);


# Check good custom dir
my $tempdir = File::Temp::tempdir(
                "testtempdirXXXXXX",
                DIR => "/tmp",
                CLEANUP => 1,
              );

$obj = DTrace::UStackResolve->new( { pids => [ $$ ],
                                     output_dir => $tempdir,
                                     runtime    => 'sec',
                                   } );
cmp_ok( $obj->output_dir, 'eq', $tempdir,
        "CUSTOM output dir is $tempdir" );

# Check non-writeable temp dir
my $changed = chmod 0500, $tempdir;
cmp_ok($changed, '==', 1, 'chmod altered one dir');
dies_ok(
  sub {
    my $obj = DTrace::UStackResolve->new( { pids => [ $$ ],
                                            output_dir => $tempdir,
                                            runtime    => '1sec',
                                          } );
  },
  "Should die for non-writeable output dir $tempdir"
);

done_testing();

