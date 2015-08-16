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
}

sub test_constructor {
  my ($test) = shift;

  can_ok( $test->test_class, 'new' );

}

sub test_constants {
  my ($test) = shift;

  my ($obj) = $test->test_class->new();
  isa_ok($obj, $test->test_class);

  can_ok( $test->test_class, 'NM' );
  diag $obj->dump;
  #diag $obj->NM;
  #is( defined($obj->NM), 1,
  #    'nm constant found' );
}

