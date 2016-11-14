# NOTE: TF stands for TestsFor::...
package TF::DTrace::UStackResolve;

use File::Temp          qw();
use Data::Dumper        qw( Dumper );
use Assert::Conditional qw();
# Possible alternative assertion methodology
# use Devel::Assert     qw();

use Test::Class::Moose;
with 'Test::Class::Moose::Role::AutoUse';


# Set up for schema
# BEGIN { use DTrace::UStackResolve::Schema; }

sub test_startup {
  my ($test, $report) = @_;
  $test->next::method;

  # ... Anything you need to do...

  my $obj = $test->class_name->new( { pids       => [ $$ ],
                                      runtime    => '1min',
                                    } );
  $test->{obj} = $obj;
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

  my ($obj) = $test->{obj};

  cmp_ok( $obj->user_stack_frames , '==', 100,
          'implict default user_stack_frames setting to 100' );


  $obj = $test->class_name->new( { pids => [ $$ ],
                                   user_stack_frames => 1,
                                   runtime           => '1min',
                                  } );
  cmp_ok( $obj->user_stack_frames , '==', 1,
          'explicit user_stack_frames setting to 1' );

  # Make sure selecting user_stack_frames outside the range dies
  dies_ok( sub {
             $test->class_name->new( { pids => [ $$ ],
                                       user_stack_frames => 0,
                                       runtime           => '1min',
                                     } );
           },
           'below user_stack_frames range should die' );
  dies_ok( sub {
             $test->class_name->new( { pids => [ $$ ],
                                       user_stack_frames => 101,
                                       runtime           => '1min',
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
                                   runtime    => '1min',
                                 } );

  cmp_ok($obj->type, 'eq', "profile", "Default DTrace type is profile");
}

sub test_bad_dtrace_type {
  my ($test) = shift;

  dies_ok(
    sub {
      my $obj = $test->class_name->new( { pids       => [ $$ ],
                                          runtime    => '1min',
                                          type       => 'bogus', } );
    },
    "Bad DTrace type is flagged"
  );
}

1;
