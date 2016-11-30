# NOTE: TF stands for TestsFor::...
package TF::DTrace::UStackResolve;

use File::Temp          qw();
use Data::Dumper        qw( Dumper );
use Assert::Conditional qw();
# Possible alternative assertion methodology
# use Devel::Assert     qw();
use IO::Async::Test;
use IO::Async::Loop;

use Test::Class::Moose;
with 'Test::Class::Moose::Role::AutoUse';

my ($loop) = IO::Async::Loop->new;

testing_loop( $loop );

# override with one that waits 20 secs instead of just 10
{
  # lexically scope, so no warnings is confined to this block
  no warnings 'redefine';
  sub IO::Async::Test::wait_for (&)
  {
     my ( $cond ) = @_;

     my ( undef, $callerfile, $callerline ) = caller;

     my $timedout = 0;
     my $timerid = $loop->watch_time(
        after => 20,
        code => sub { $timedout = 1 },
     );

     $loop->loop_once( 1 ) while !$cond->() and !$timedout;

     if( $timedout ) {
        die "Nothing was ready after 20 second wait; called at $callerfile line $callerline\n";
     } else {
        $loop->unwatch_time( $timerid );
     }
  }
}

# Set up for schema
# BEGIN { use DTrace::UStackResolve::Schema; }

sub test_startup {
  my ($test, $report) = @_;
  $test->next::method;

  # ... Anything you need to do...

  my $obj = $test->class_name->new( { pids       => [ $$ ],
                                      runtime    => '1sec',
                                    } );
  $obj->resolver_func->stop;
  $obj->sha1_func->stop;
  $obj->pldd_func->stop;
  $obj->gen_symtab_func->stop;
  $test->{obj}  = $obj;
  $test->{loop} = $loop;
}

sub test_constructor {
  my ($test) = shift;

  can_ok( $test->class_name, 'new' );
}

sub test_constants {
  my ($test) = shift;

  my $obj = $test->{obj};
  isa_ok($obj, $test->class_name, "object is of type " . $test->class_name);

  my @constants = qw( PLDD ELFDUMP PGREP DTRACE );

  foreach my $constant( @constants ) {
    is( defined($obj->$constant), 1,
        "$constant constant is defined" );
  }

  if ($^O eq "solaris") {
    foreach my $constant (@constants) {
      is( -e $obj->$constant, 1, "Location for $constant exists" );
    }
  } else {
    diag "SKIPPING check for presence of constant paths - only valid on Solaris";
  }
}

sub test_loop {
  my ($test) = shift;

  my $obj = $test->{obj};

  isa_ok( $obj->loop, 'IO::Async::Loop' );
  # TODO: Create a new loop, and ensure that it's a singleton by confirming it's
  #       identical to the one that's stored in the object already
}


sub test_user_stack_frames {
  my ($test) = shift;

  my ($obj) = $test->class_name->new( { pids         => [ $$ ],
                                        runtime      => '1sec',
                                      } );


  cmp_ok( $obj->user_stack_frames , '==', 100,
          'implict default user_stack_frames setting to 100' );

  $obj->resolver_func->stop;
  $obj->sha1_func->stop;
  $obj->pldd_func->stop;
  $obj->gen_symtab_func->stop;

  $obj = $test->class_name->new( { pids              => [ $$ ],
                                   user_stack_frames => 1,
                                   runtime           => '1sec',
                                  } );

  cmp_ok( $obj->user_stack_frames , '==', 1,
          'explicit user_stack_frames setting to 1' );

  $obj->resolver_func->stop;
  $obj->sha1_func->stop;
  $obj->pldd_func->stop;
  $obj->gen_symtab_func->stop;

  # Make sure selecting user_stack_frames outside the range dies
  dies_ok( sub {
             $test->class_name->new( { pids              => [ $$ ],
                                       user_stack_frames => 0,
                                       runtime           => '1sec',
                                     } );
           },
           'below user_stack_frames range should die' );

  dies_ok( sub {
             $test->class_name->new( { pids => [ $$ ],
                                       user_stack_frames => 101,
                                       runtime           => '1sec',
                                     } );
           },
           'above user_stack_frames range should die' );
}

#sub test_pids {
#  my ($test) = shift;
#
#  my ($obj, $pids_aref);
#
#  $obj = $test->class_name->new( { execname => $test->{execname_attribute} } );
#
#  $pids_aref = $obj->pids;
#
#  cmp_deeply( $pids_aref, bag( re(qr/^\d+$/) ) );
#}

#sub test_constructor_with_pid {
#  my ($test) = shift;
#
#  my ($obj);
#
#  $obj = $test->class_name->new( { pid => $$ } );
#
#  like($obj->execname, qr/perl/, "passing pid arg produces an execname");
#}

sub test_default_dtrace_type {
  my ($test) = shift;

  my ($obj);

  $obj = $test->class_name->new( { pids       => [ $$ ],
                                   runtime    => '1sec',
                                 } );

  cmp_ok($obj->dtrace_type, 'eq', "profile", "Default DTrace type is profile");
  $obj->resolver_func->stop;
  $obj->sha1_func->stop;
  $obj->pldd_func->stop;
  $obj->gen_symtab_func->stop;
}

sub test_DTrace_pragmas {
  my ($test) = shift;

  my ($obj);

  $obj = $test->class_name->new( { pids       => [ $$ ],
                                   runtime    => '1sec',
                                 } );

  $obj->resolver_func->stop;
  $obj->sha1_func->stop;
  $obj->pldd_func->stop;
  $obj->gen_symtab_func->stop;

  cmp_ok($obj->bufsize,    'eq', '8m',    "Default bufsize is 8m");
  cmp_ok($obj->aggsize,    'eq', '6m',    "Default aggsize is 6m");
  cmp_ok($obj->aggrate,    'eq', '23Hz',  "Default aggrate is 23Hz");
  cmp_ok($obj->switchrate, 'eq', '29Hz',  "Default switchrate is 29Hz");
  cmp_ok($obj->cleanrate,  'eq', '31Hz',  "Default cleanrate is 31Hz");
  cmp_ok($obj->dynvarsize, 'eq', '32m',   "Default dynvarsize is 32m");
  cmp_ok($obj->nworkers,   'eq', '8',     "Default nworkers is 8");

  $obj = $test->class_name->new( { pids       => [ $$ ],
                                   runtime    => '1sec',
                                   bufsize    => '1m',
                                   aggsize    => '2m',
                                   aggrate    => '2Hz',
                                   switchrate => '3Hz',
                                   cleanrate  => '4Hz',
                                   dynvarsize => '13m',
                                   nworkers   => '5',
                                 } );

  $obj->resolver_func->stop;
  $obj->sha1_func->stop;
  $obj->pldd_func->stop;
  $obj->gen_symtab_func->stop;

  cmp_ok($obj->bufsize,    'eq', '1m',    "Specified bufsize is 1m");
  cmp_ok($obj->aggsize,    'eq', '2m',    "Specified aggsize is 2m");
  cmp_ok($obj->aggrate,    'eq', '2Hz',   "Specified aggrate is 2Hz");
  cmp_ok($obj->switchrate, 'eq', '3Hz',   "Specified switchrate is 3Hz");
  cmp_ok($obj->cleanrate,  'eq', '4Hz',   "Specified cleanrate is 4Hz");
  cmp_ok($obj->dynvarsize, 'eq', '13m',   "Specified dynvarsize is 13m");
  cmp_ok($obj->nworkers,   'eq', '5',     "Specified dynvarsize is 5");
}


sub test_bad_dtrace_type {
  my ($test) = shift;

  dies_ok(
    sub {
      my $obj = $test->class_name->new( { pids        => [ $$ ],
                                          runtime     => '1sec',
                                          dtrace_type => 'bogus', } );
    },
    "Bad DTrace type is flagged"
  );
}

sub test_preserve_tempfiles {
  my ($test) = shift;
  #
  # Dumb down DTrace pragmas to make the dtrace start fast
  #
  my $obj = $test->class_name->new( { pids               => [ $$ ],
                                      runtime            => '1sec',
                                      bufsize            => '8k',
                                      aggsize            => '8k',
                                      aggrate            => '1Hz',
                                      switchrate         => '1Hz',
                                      cleanrate          => '1Hz',
                                      dynvarsize         => '2m',
                                      preserve_tempfiles => 1,
                                    }
                                  );
  cmp_ok( $obj->loop, 'eq', $test->{loop},
          'Test and Object Loop are identical' );

  my $dtrace_script_file     = $obj->dtrace_script_fh->filename;
  my $dtrace_unresolved_file = $obj->dscript_unresolved_out_fh->filename;
  my $dtrace_STDERR_file     = $obj->dscript_err_fh->filename;

  cmp_ok( $obj->preserve_tempfiles, '==', 1, 'preserve_tempfiles is ENABLED' );

  # Wait for DTrace to start and finish
  wait_for { ! $obj->dtrace_process->is_running };
  ok( $obj->dtrace_process->is_exited, 'DTrace WITH temp file preservation exited' );
  # Do basic cleanup
  $obj->clear_dtrace_script_fh;
  $obj->clear_dscript_unresolved_out_fh;
  $obj->clear_dscript_err_fh;
  $obj->resolver_func->stop;
  $obj->sha1_func->stop;
  $obj->pldd_func->stop;
  $obj->gen_symtab_func->stop;

  # Check that files still exist
  ok( -f $dtrace_script_file,
      "DTrace Script Temp file [$dtrace_script_file] preserved");
  ok( -f $dtrace_unresolved_file,
      "DTrace Unresolved Output Temp file [ $dtrace_unresolved_file] preserved");
  ok( -f $dtrace_STDERR_file,
      "DTrace STDERR Output Temp file [$dtrace_STDERR_file] preserved");

  # Cleanup files after we're done testing
  unlink $dtrace_script_file, $dtrace_unresolved_file, $dtrace_STDERR_file;

  # Now create object without tempfile_preserve specified, so files should get
  # cleaned up by default
  $obj = $test->class_name->new( { pids              => [ $$ ],
                                   runtime           => '1sec',
                                   bufsize            => '8k',
                                   aggsize            => '8k',
                                   aggrate            => '1Hz',
                                   switchrate         => '1Hz',
                                   cleanrate          => '1Hz',
                                   dynvarsize         => '2m',
                                 }
                               );

  $dtrace_script_file     = $obj->dtrace_script_fh->filename;
  $dtrace_unresolved_file = $obj->dscript_unresolved_out_fh->filename;
  $dtrace_STDERR_file     = $obj->dscript_err_fh->filename;

  cmp_ok( $obj->preserve_tempfiles, '==', 0, 'preserve_tempfiles is DISABLED' );

  # Wait for DTrace to start and finish
  wait_for { ! $obj->dtrace_process->is_running };
  ok( $obj->dtrace_process->is_exited, 'DTrace without temp file preservation exited' );
  # Do basic cleanup
  $obj->clear_dtrace_script_fh;
  $obj->clear_dscript_unresolved_out_fh;
  $obj->clear_dscript_err_fh;
  $obj->resolver_func->stop;
  $obj->sha1_func->stop;
  $obj->pldd_func->stop;
  $obj->gen_symtab_func->stop;

  # Wait for object destruction and file deletion
  sleep 1;
  # Check that files were NOT preserved
  ok( ! -f $dtrace_script_file,
      "DTrace Script Temp file [$dtrace_script_file] eliminated");
  ok( ! -f $dtrace_unresolved_file,
      "DTrace Unresolved Output Temp file [$dtrace_unresolved_file] eliminated");
  ok( ! -f $dtrace_STDERR_file,
      "DTrace STDERR Output Temp file [$dtrace_STDERR_file] eliminated");

  # No cleanup should be necessary
}

1;
