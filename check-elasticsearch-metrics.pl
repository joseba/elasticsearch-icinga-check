#!/usr/bin/perl
use LWP::UserAgent; 
use JSON::XS;
use Getopt::Std;
use Time::HiRes qw(gettimeofday);
use Time::Piece;
use DateTime::Format::Strptime;

my $args = "rc:w:s:a:t:f:q:h:p:x:d:n:m:y:i:";
getopts("$args", \%opt);

if(!defined $opt{s}){
  return inputError('s');
}
if(!defined $opt{c} ){
  return inputError('c');
}
if(!defined $opt{w}){
  return inputError('w');
}
if(!defined $opt{q}){
  return inputError('q');
}
if(!defined $opt{h}){
  return inputError('h');
}
if(!defined $opt{n}){
  return inputError('n');
}
if(!defined $opt{x}){
  return inputError('x');
}
if(!defined $opt{y}){
  return inputError('y');
}
if(!defined $opt{m}){
  return inputError('m');
}
if(!defined $opt{p}){
  $opt{p} = 9200;
}
if(!defined $opt{i}){
  $opt{i} = 2;
}

my $indexCount = 1;
my $rawNow = localtime;
my $rawFrom = $rawNow - $opt{s};
my $now = $rawNow->epoch * 1000;
my $fromTime = $rawFrom->epoch * 1000;
my $critical = $opt{c};
my $warning = $opt{w};
my $reverse = $opt{r};
my $aggregationName = $opt{a};
my $aggregationType = $opt{t};
my $field = $opt{f};
my $query = $opt{q};
my $host = $opt{h};
my $port = $opt{p};
my $indexPattern = $opt{n};
my $earliestIndexCount = $opt{i};
my $hasDays = defined $opt{d};
my $hasAggregation = $aggregationName && $aggregationType && $field;

makeElasticsearchRequest();

sub makeElasticsearchRequest {
  my $ua = LWP::UserAgent->new;
  $ua->agent("Icinga Check/0.1 ");
  
  my $indices = buildIndices();

  my $req = HTTP::Request->new(POST => "http://$host:$port/$indices/_search");
  $req->content_type('application/json');
  my $content = "{
    \"size\": 0,
    \"query\": {
      \"filtered\": {
        \"query\": {
          \"query_string\": {
            \"query\": \"$query\",
            \"analyze_wildcard\": true
          }
        },
        \"filter\": {
          \"bool\": {
            \"must\": [
              {
                \"range\": {
                  \"\@timestamp\": {
                    \"gte\": $fromTime,
                    \"lte\": $now,
                    \"format\": \"epoch_millis\"
                  }
                }
              }
            ],
            \"must_not\": []
          }
        }
      }
    }";
  if($hasAggregation){
    $content = "$content,\"aggs\": {
        \"$aggregationName\": {
          \"$aggregationType\": {
            \"field\": \"$field\"
          }
        }
      }";
  }
  $content = "$content }";
  $req->content($content);
  my $res = $ua->request($req);
  parseElasticsearchResponse($res);
}

sub buildIndices {
  my $indexCount = 1;
  my $index;
  my $pattern = "%Y/%m";
  if($hasDays){
    $pattern = "$pattern/%d";
  }
  my $parser = DateTime::Format::Strptime->new(
    pattern => $pattern,
    on_error => 'croak',
  );
  my $date = "$opt{y}/$opt{m}";
  if($hasDays){
    $date = "$date/$opt{d}";
  }
  my $now = $parser->parse_datetime($date);
  while ($indexCount <= $earliestIndexCount){
    my $year = $now->year;
    my $month = $now->month;
    if($month < 10){
      $month = "0$month"
    }
    my $day = $now->day;
    if($day < 10){
      $day = "0$day"
    }
    $index = "$index$indexPattern";
    $index =~ s/{prefix}/$opt{x}/g;
    $index =~ s/{yyyy}/$year/g;
    $index =~ s/{mm}/$month/g;
    $index =~ s/{dd}/$day/g;
    $index = "$index,";
    if($hasDays){
      $now->subtract(days => 1);
    } else {
      $now->subtract(months => 1);
    }
    $indexCount++;
  }
  chop($index);
  printf "$index\n";
  return $index
}

sub parseElasticsearchResponse {
  my ($res) = @_;
  if ($res->is_success) {
    my $content = $res->content;
    my %parsed = %{decode_json $content};
    my $value = -1;
    if($hasAggregation){
      my %aggregations = %{$parsed{aggregations}};
      my %aggValue = %{$aggregations{$aggregationName}};
      $value = $aggValue{value};
    } else {
      my %hits = %{$parsed{hits}};
      $value = $hits{total};
    }
    
    my $alertStatus = getAlertStatus($value);
    print "\nExited with: $alertStatus, Current Value: $value, Critical: $critical, Warning: $warning\n";
    exit $alertStatus;
  }
  else {
      print $res->status_line, " from elasticsearch\n";
      exit 3;
  }
}

sub getAlertStatus {
  my ($esvalue) = @_;
  if($reverse){
    if($esvalue <= $critical){
      return 2;
    }
    if($esvalue <= $warning){
      return 1;
    }
  }
  else {
    if($esvalue >= $critical){
      return 2;
    }
    if($esvalue >= $warning){
      return 1;
    }
  }

  return 0;
}

sub help {
  print "\nObtains metrics from elasticsearch to power Icinga alerts\n";
  print "\nUsage: check-elasticsearch-metrics.pl [OPTIONS]\n";
  print "\nRequired Settings:\n";
  print "\t-c [threshold]: critical threshold\n";
  print "\t-w [threshold]: warning threshold\n";
  print "\t-s [seconds]: number of seconds from now to check\n";
  print "\t-q [query_string]: the query to run in elasticsearch\n";
  print "\t-h [host]: elasticsearch host\n";
  print "\t-i [number_of_indices]: the number of indices to go back through, defaults to 2\n";
  print "\t-x [indices_prefix]: the prefix of your elasticsearch indices\n";
  print "\t-m [month]: the month of your latest elasticsearch index\n";
  print "\t-n [index_pattern]: the pattern expects a prefix and months or years, e.g: {prefix}-{yyyy}.{mm}\n";
  print "\t-y [year]: the year of your latest elasticsearch index\n\n";
  print "\tOptional Settings:\n";
  print "\t-?: this help message\n";
  print "\t-r: reverse threshold (so amounts below threshold values will alert)\n";
  print "\t-q [port]: elasticsearch port (defaults to 9200)\n";
  print "\t-a [name]: aggregation name\n";
  print "\t-t [type]: aggregation type\n";
  print "\t-f [field_name]: the name of the field to aggregate\n";
  print "\t-d [day]: the day of your latest elasticsearch index\n\n";
  print "Error codes:\n";
  print "\t0: Everything OK, check passed\n";
  print "\t1: Warning threshold breached\n";
  print "\t2: Critical threshold breached\n";
  print "\t3: Unknown, encountered an error querying elasticsearch\n";
}

sub inputError {
  my ($option) = @_;
  print STDERR "\n\n\t\tMissing required parameter \"$option\"\n\n";
  help();
  exit 3;
}