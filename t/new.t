use strict;
use warnings;

use v5.22;
use Test::Most;
use Data::Dumper;
use IO::Async::Loop;
use Digest::SHA1;
use Digest::MD5;
#use Crypt::CBC;
use IO::File;
use Time::HiRes qw(gettimeofday tv_interval);

use_ok('DTrace::UStackResolve');

# This is the "first" loop - since this is a singleton, the
# DTrace::UStackResolve object will 're-initialize' it, which is to say it'll
# just use the same one
#
my $loop = IO::Async::Loop->new;

my ($pid) =
  $loop->spawn_child(
    code => sub {
      my $t0 = [gettimeofday];
      OUTER:
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
            my $elapsed = tv_interval($t0);
            if ($elapsed > 7) {
              last OUTER;
            }

            my $fh = IO::File->new("$dir/$file","<") or next;
            my $c = do { local $/; <$fh>; };
            my ($digest) = Digest::SHA1::sha1_hex($c);
            $digest = Digest::MD5::md5_hex($c);
            #my ($cipher) = Crypt::CBC->new( -key => 'super secret key',
            #                                -cipher => 'Blowfish',
            #                              );
            #my ($ciphertext) = $cipher->encrypt($c);
          }
        }
      }
      return 0;
    },
    on_exit => sub {
      my ($pid, $exitcode, $dollarbang, $dollarat) = @_;
      my $status = ($exitcode >> 8);
      print "Child process exited with status $status\n";
      #print " OS Error was $dollarbang, exception was $dollarat\n";
      $loop->stop();
    },
  );

my $obj = DTrace::UStackResolve->new( { pids => [ $pid ] } );

isa_ok($obj, 'DTrace::UStackResolve', 'object is the right type');

# It's ok to use the $loop we defined here, as it'll be the same as the one we'd
# pull out of the $obj anyway
$loop->run();

done_testing();

