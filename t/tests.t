use Test::Class::Moose::Load 't/lib';

my $test_suite = Test::Class::Moose->new(
  show_timing  => 0,
  randomize    => 0,
  statistics   => 1,
  test_classes => \@ARGV,
);

$test_suite->runtests;

my $report = $test_suite->test_report;

