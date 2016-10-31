use strict;
use warnings;

use Test::Most;
use Data::Dumper;
use Digest::SHA1;
use IO::File;

use_ok('DTrace::UStackResolve');

my $pid = $$;

my $obj = DTrace::UStackResolve->new( { pids => [ $pid ] } );

isa_ok($obj, 'DTrace::UStackResolve', 'object is the right type');

for (my $i = 0; $i <= 1000; $i++) {
  opendir(DH, "/usr/bin");
  my @files = readdir(DH);
  closedir(DH);
  
  foreach my $file (@files) {
    next if ($file =~ /^\.$/);
    next if ($file =~ /^\.\.$/);
  
    stat($file);
    if (-f $file) {
      my $fh = IO::File->new($file,"<");
      my $c = do { local $/; <$fh>; };
      my ($digest) = Digest::SHA1::sha1_hex($c);
    }
  }
}

sleep(2);

done_testing();

