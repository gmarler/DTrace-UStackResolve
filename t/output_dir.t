use strict;
use warnings;

use v5.22;
use Test::Most;
use File::Temp      qw();
use Data::Dumper;

use_ok('DTrace::UStackResolve');

# Check the default
my $obj = DTrace::UStackResolve->new( { pids => [ $$ ] } );

cmp_ok( $obj->output_dir, 'eq', "/tmp",
        "Default output dir is /tmp" );

# Check non-existent dir
dies_ok(
  sub {
    my $obj = DTrace::UStackResolve->new( { pids => [ $$ ],
                                            output_dir => '/my/bogus/dir',
                                          } );
  },
  'Should die with non-existent output dir'
);


# Check good custom dir
my $tempdir = File::Temp::tempdir(
                "testtempdirXXXXXX",
                DIR => "/tmp",
                CLEANUP => 0,
              );
my $dirname = $tempdir->dirname;
diag "Created temporary directory $dirname";
$obj = DTrace::UStackResolve->new( { pids => [ $$ ],
                                     output_dir => $dirname,
                                   } );
cmp_ok( $obj->output_dir, 'eq', $dirname,
        "Default output dir is $dirname" );

# Check non-writeable temp dir
chmod "0500", $dirname;
dies_ok(
  sub {
    my $obj = DTrace::UStackResolve->new( { pids => [ $$ ],
                                            output_dir => $dirname,
                                          } );
  },
  "Should die with non-writeable output dir $dirname"
);

done_testing();

