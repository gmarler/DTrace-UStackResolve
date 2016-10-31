use strict;
use warnings;

use v5.22;
use Test::Most;
use Data::Dumper;
use IO::Async::Loop;
use Digest::SHA1;
use Digest::MD5;
use Crypt::CBC;
use IO::File;

use_ok('DTrace::UStackResolve');

my $loop = IO::Async::Loop->new;

my ($pid) =
  $loop->spawn_child(
    code = sub {
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
      return 1;
    },
    on_exit => sub {
      my ($pid, $exitcode, $dollarbang, $dollarat) = @_;
      my $status = ($exitcode >> 8);
      print "Child process exited with status $status\n";
      print " OS Error was $dollarbang, exception was $dollarat\n";
    },
  );

my $obj = DTrace::UStackResolve->new( { pids => [ $pid ] } );

isa_ok($obj, 'DTrace::UStackResolve', 'object is the right type');

sleep(2);

done_testing();

