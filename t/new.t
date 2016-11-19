use strict;
use warnings;

use v5.22;
use Test::Most;
use Data::Dumper;
use IO::Async::Loop;
use IO::File;
use File::Find ();

use_ok('DTrace::UStackResolve');

# This is the "first" loop - since this is a singleton, the
# DTrace::UStackResolve object will simply reuse it if we try to
# IO::Async::Loop->new() it again.
#
#
my $loop = IO::Async::Loop->new;

# Here we just launch a pid that does a lot of CPU intensive work of some kind,
# so that the DTrace profile will produce stack output that has to be resolved.
my ($pid) =
  $loop->spawn_child(
    setup => [
      stdin  => [ "open", "<", "/dev/null" ],
      stdout => [ "open", ">", "/dev/null" ],
      stderr => [ "open", ">", "/dev/null" ],
    ],
    code  => sub {

      # for the convenience of &wanted calls, including -eval statements:
      use vars qw/*name *dir *prune/;
      *name   = *File::Find::name;
      *dir    = *File::Find::dir;
      *prune  = *File::Find::prune;

      sub wanted;

      # Traverse desired filesystems
      File::Find::find({wanted => \&wanted}, '/');
      return 0;

      sub wanted {
        my ($dev,$ino,$mode,$nlink,$uid,$gid);

        (($dev,$ino,$mode,$nlink,$uid,$gid) = lstat($_)) &&
        -f _ &&
        print("$name\n");
      }
    },
    on_exit => sub {
      my ($pid, $exitcode, $dollarbang, $dollarat) = @_;
      my $status = ($exitcode >> 8);
      print "Child process exited with status $status\n";
      #print " OS Error was $dollarbang, exception was $dollarat\n";
      $loop->stop();
    },
  );

# Use the runtime arg to have the DTrace stop producing output in 10 seconds
my $obj = DTrace::UStackResolve->new( { pids => [ $pid ],
                                        runtime => '10sec',
                                      }
                                    );

isa_ok($obj, 'DTrace::UStackResolve', 'object is the right type');

# It's ok to use the $loop we defined here, as it'll be the same as the one we'd
# pull out of the $obj anyway
$loop->run();

# Once we fall out of the loop, kill the working pid
kill 'TERM', $pid;

done_testing();

