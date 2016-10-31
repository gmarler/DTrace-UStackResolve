use strict;
use warnings;

use Test::Most;
use Data::Dumper;

use_ok('DTrace::UStackResolve');

my $pid = $$;

my $obj = DTrace::UStackResolve->new( { pids => [ $pid ] } );

isa_ok($obj, 'DTrace::UStackResolve', 'object is the right type');

for (my $i = 0; $i <= 1000; $i++) {
  opendir(DH, "/etc");
  my @files = readdir(DH);
  closedir(DH);
  
  foreach my $file (@files) {
    next if ($file =~ /^\.$/);
    next if ($file =~ /^\.\.$/);
  
    stat($file);
    if (-f $file) {
    }
    if (-x $file) {
    }
    if (-d $file) {
    }
    if (-l $file) {
    }
  }
}

sleep(2);

done_testing();

