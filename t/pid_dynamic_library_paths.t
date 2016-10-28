use strict;
use warnings;

use Test::Most;
use Data::Dumper;

use_ok('DTrace::UStackResolve');

my $pid = $$;

my $aref = DTrace::UStackResolve::_pid_dynamic_library_paths($pid);

# Does each library returned actually exist?
sub does_file_exist {
  my ($file) = shift;

  if (-f $file) {
    return 1;
  } else {
    return 0;
  }
}
cmp_deeply( $aref, array_each( code(\&does_file_exist) ),
           'library files exist' );

done_testing();

