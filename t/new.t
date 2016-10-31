use strict;
use warnings;

use v5.22;
use Test::Most;
use Data::Dumper;
use Digest::SHA1;
use Digest::MD5;
use Crypt::CBC;
use IO::File;

use_ok('DTrace::UStackResolve');

my $pid = $$;

my $obj = DTrace::UStackResolve->new( { pids => [ $pid ] } );

isa_ok($obj, 'DTrace::UStackResolve', 'object is the right type');

for (my $i = 0; $i <= 1000; $i++) {
  foreach my $dir (qw(/usr/bin /usr/bin/sparcv9 /usr/sbin /usr/lib
                      /usr/lib/sparcv9)) {
    opendir(DH, $dir);
    my @files = readdir(DH);
    closedir(DH);
    
    foreach my $file (@files) {
      next if ($file =~ /^\.$/);
      next if ($file =~ /^\.\.$/);
    
      stat("$dir/$file");
      if (-f "$dir/$file") {
        my $fh = IO::File->new("$dir/$file","<");
        my $c = do { local $/; <$fh>; };
        say "File length: " . length($c);
        my ($digest) = Digest::SHA1::sha1_hex($c);
        $digest = Digest::MD5::md5_hex($c);
        my ($cipher) = Crypt::CBC->new( -key => 'super secret key',
                                        -cipher => 'Blowfish',
                                      );
        my ($ciphertext) = $cipher->encrypt($c);
      }
    }
  }
}

sleep(2);

done_testing();

