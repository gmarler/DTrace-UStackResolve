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

  # Picking an execname that EXTREMELY likely to be running on any Solaris
  $test->{execname_attribute} = '/usr/sbin/nscd';
}

sub test_constructor {
  my ($test) = shift;

  can_ok( $test->class_name, 'new' );
}

sub test_constants {
  my ($test) = shift;

  my @constants = qw( PMAP NM PGREP DTRACE );

  can_ok( $test->class_name, @constants );
  my $obj = $test->class_name->new( execname => $test->{execname_attribute} );

  #diag $obj->dump;

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

  my $obj = $test->class_name->new( execname => $test->{execname_attribute} );
  isa_ok( $obj->loop, 'IO::Async::Loop' );
}

sub test_autoflush_dtrace_output {
  my ($test) = shift;

  my ($obj);
  $obj = $test->class_name->new( execname => $test->{execname_attribute},
                                 autoflush_dtrace_output => 0 );
  cmp_ok( $obj->autoflush_dtrace_output, '==', 0,
         'explicit autoflush_dtrace_output setting to 0' );

  $obj = $test->class_name->new( execname => $test->{execname_attribute} );
  cmp_ok( $obj->autoflush_dtrace_output, '==', 0,
         'implicit default autoflush_dtrace_output setting to 0' );
  $obj = $test->class_name->new( execname => $test->{execname_attribute},
                                 autoflush_dtrace_output => 1 );
  cmp_ok( $obj->autoflush_dtrace_output, '==', 1,
         'explicit autoflush_dtrace_output setting to 1' );
  # TODO: Actually test whether the autoflush *happens*
}


sub test_user_stack_frames {
  my ($test) = shift;

  my ($obj);

  $obj = $test->class_name->new( execname => $test->{execname_attribute} );
  cmp_ok( $obj->user_stack_frames , '==', 100,
          'implict default user_stack_frames setting to 100' );


  $obj = $test->class_name->new( execname => $test->{execname_attribute},
                                 user_stack_frames => 1, );
  cmp_ok( $obj->user_stack_frames , '==', 1,
          'explicit user_stack_frames setting to 1' );

  # Make sure selecting user_stack_frames outside the range dies
  dies_ok( sub {
             $test->class_name->new( execname => $test->{execname_attribute},
                                     user_stack_frames => 0 );
           },
           'below user_stack_frames range should die' );
  dies_ok( sub {
             $test->class_name->new( execname => $test->{execname_attribute},
                                     user_stack_frames => 101 );
           },
           'above user_stack_frames range should die' );
}

sub test_pids {
  my ($test) = shift;

  my ($obj, $pids_aref);

  $obj = $test->class_name->new( execname => $test->{execname_attribute} );

  $pids_aref = $obj->pids;

  cmp_deeply( $pids_aref, bag( re(qr/^\d+$/) ) );
}

1;
