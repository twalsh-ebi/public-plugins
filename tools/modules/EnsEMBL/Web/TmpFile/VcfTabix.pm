=head1 LICENSE

Copyright [1999-2015] Wellcome Trust Sanger Institute and the EMBL-European Bioinformatics Institute
Copyright [2016-2018] EMBL-European Bioinformatics Institute

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

     http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

=cut

package EnsEMBL::Web::TmpFile::VcfTabix;

## EnsEMBL::Web::TmpFile::VcfTabix - module for dealing with tabix indexed VCF
## files generated by the VEP

use strict;
use warnings;

use EnsEMBL::Web::SpeciesDefs;
use EnsEMBL::Web::Exceptions;

use Bio::EnsEMBL::Variation::Utils::VEP qw(@OUTPUT_COLS);

use parent qw(EnsEMBL::Web::TmpFile::ToolsOutput);

sub compress { return 1; }

sub content {
  ## Gets the content of the file in required format
  ## @param Hash with keys as accepted by content_iterate method.
  my ($self, %params) = @_;

  my @content;

  $self->content_iterate(\%params, sub { push @content, @_ });

  return join "\n", @content;
}

sub content_parsed {
  ## Gets the parsed content from the file
  ## @param Hashref with keys as accepted by content_iterate except the 'format' key
  my ($self, $params) = @_;

  delete $params->{'format'};
  $params->{'parsed'} = 1;

  my $line_number = 0;
  my (@rows, $headers);

  $self->content_iterate($params, sub {
    if ($headers) {
      $line_number++;
      push @rows, @_;
    } else {
      $headers = $_[0];
    }
  });

  return [ $headers, \@rows, $line_number ];
}

sub content_iterate {
  ## Triggers a callback for each line of the content
  ## @param Hashref with keys:
  ##  - from      : Return line number after
  ##  - to        : Return line number before
  ##  - location  : Chromosome location
  ##  - filter    : Filter to be applied using the filter script
  ##  - format    : Requested output format
  ##  - parsed    : Flag on if parsed rows are needed (not compatible with 'format')
  ## @param Callback subroutine
  my ($self, $params, $callback) = @_;

  my $file          = $self->{'full_path'};
  my $species_defs  = EnsEMBL::Web::SpeciesDefs->new;

  # normal
  unless (keys %$params) {
    $callback->($_) for split /\R/, $self->SUPER::content;
    return;
  }

  # get args
  my $from = $params->{'from'} || 0;
  my $to   = $params->{'to'}   || 1e12;
  my $loc  = $params->{'location'};

  # create commandline to read file
  my $fh_string = defined $loc && $loc =~ /\w+/ ? "tabix -h $file $loc | " : "gzip -dcq $file | ";

  # if filtering, pipe the output to the filter script
  if ($params->{'filter'}) {

    # get perl binary, script path and command line options for the script
    my $script  = $species_defs->ENSEMBL_VEP_FILTER_SCRIPT or throw exception('VcfTabixError', 'No filter_vep.pl script defined (ENSEMBL_VEP_FILTER_SCRIPT)');
       $script  = join '/', $species_defs->ENSEMBL_SERVERROOT, $script;
    my $perl    = sprintf 'perl -I %s -I %s', $species_defs->ENSEMBL_SERVERROOT.'/ensembl/modules', $species_defs->BIOPERL_DIR;
    my $opts    = $species_defs->ENSEMBL_VEP_FILTER_SCRIPT_OPTIONS || {};
       $opts    = join ' ', map { defined $opts->{$_} ? "$_ $opts->{$_}" : () } keys %$opts;

    # add tmp dir root to paths
    if($params->{'filter'} =~ m/ in /) {
      my $td = $species_defs->ENSEMBL_TMP_DIR;
      $params->{'filter'} =~ s/( in )([a-z0-9]+)/$1 $td\/$2/g;
    }

    # build the commandline
    $fh_string .= sprintf("%s %s %s -filter '%s' -format vcf -ontology -only_matched -start %i -limit %i 2>&1 | ", $perl, $script, $opts, $params->{'filter'}, $from, ($to - $from) + 1);
  }

  my $all_headers;
  my $line_number = 0;
  my $format_method = defined $params->{'format'} && $params->{'format'} ne 'vcf' && $self->can("_convert_to_$params->{'format'}");
  my $first_line = 1;
  my @header_lines;

  open(my $fh, $fh_string);

  while (<$fh>) {

    chomp;

    if ($first_line) {
      throw exception('VcfTabixError', "Header missing: $_") unless $_ =~ /^\#/;
      $first_line = 0;
    }

    # filter_vep.pl takes care of limiting - so no filters, we have to do the limiting here
    if (!$params->{'filter'}) {
      $line_number++ unless m/^\#/;
      next if !m/^\#/ && $line_number < $from;
      last if $line_number > $to;
    }

    # if non-vcf format requested
    if ($format_method || $params->{'parsed'}) {

      # header is not parsed
      if (!$all_headers) {
        if (m/^\#/) {
          push @header_lines, $_;
        } else {
          $all_headers = $self->_parse_headers(\@header_lines);
          $callback->($params->{'parsed'} ? $all_headers : @{$format_method->($self, $all_headers->{'combined'})});
        }
      }

      if ($all_headers && !m/^\#/) {
        my $rows = $self->_parse_line($all_headers, $_);
        $callback->($params->{'parsed'} ? @$rows : @{$format_method->($self, $all_headers->{'combined'}, $rows)});
      }
    } else { # vcf format requested
      $callback->($_);
    }
  }

  # if a filter returns 0 rows, $all_headers won't exist yet
  if(($format_method || $params->{'parsed'}) && !$all_headers) {
    $all_headers = $self->_parse_headers(\@header_lines);
    $callback->($params->{'parsed'} ? $all_headers : @{$format_method->($self, $all_headers->{'combined'})});
  }

  close $fh;
}

sub _convert_to_txt {
  ## @private
  my ($self, $headers, $rows) = @_;

  my @lines;

  if ($rows) {
    foreach my $row (@$rows) {
      $row->{'Uploaded_variation'} ||= $row->{'ID'} if $row->{'ID'};
      push @lines, join("\t", map { ($row->{$_} // '') ne '' ? $row->{$_} : '-' } @$headers);
    }
  } else {
    push @lines, '#'.join("\t", map { s/^ID$/Uploaded_variation/r; } @$headers);
  }

  return \@lines;
}

sub _convert_to_vep {
  ## @private
  my ($self, $headers, $rows) = @_;

  my @lines;

  if ($rows) {

    foreach my $row (@$rows) {

      $row->{'Uploaded_variation'} ||= delete $row->{'ID'} if $row->{'ID'};

      my (@fields, @extra);

      # get the "main" columns using @OUTPUT_COLS as defined in the VEP module
      foreach my $h(grep {$_ ne 'Extra'} @OUTPUT_COLS) {
        my $v = delete $row->{$h};
        push @fields, ($v // '') ne '' ? $v : '-';
      }

      # now get the rest of them in order as defined in $headers
      # and add them to the "Extra" field
      foreach my $i (0..$#{$headers}) {

        # get header and value
        my ($h, $v) = ($headers->[$i], $row->{$headers->[$i]});

        # extra column
        if (($v // '') ne '') {
          push @extra, sprintf '%s=%s', $h, $v;
        }
      }

      push @lines, join("\t", @fields, join(';', @extra));
    }
  } else {
    push @lines, '#'.join("\t", @OUTPUT_COLS);
  }

  return \@lines;
}

sub _parse_line {
  ## @private
  my ($self, $headers, $line) = @_;

  my $row_headers       = $headers->{'headers'};
  my $combined_headers  = $headers->{'combined'};
  my $csq_headers       = $headers->{'csq'};

  my @rows;

  my @split     = split /\s+/, $line;
  my %raw_data  = map { $row_headers->[$_] => $split[$_] } 0..$#$row_headers;

  if ($raw_data{'CHROM'} !~ /^chr_/i) {
    $raw_data{'CHROM'} =~ s/^chr(om)?(osome)?//i;
  }

  # special case location col
  my ($start, $end) = ($raw_data{'POS'}, $raw_data{'POS'});
  my ($ref, $alt)   = ($raw_data{'REF'}, $raw_data{'ALT'});

  if($line =~ m/END\=(\d+)/g) {
    $end = $1;
  }
  else {
    $end += length($ref) - 1;
  }

  $raw_data{'Location'} = sprintf('%s:%s', $raw_data{'CHROM'}, join('-', sort {$a <=> $b} $start, $end));

  if (length $ref != length $alt) {
    $ref = substr($ref, 1);
    $alt = substr($alt, 1);

    $ref ||= '-';
    $alt ||= '-';
  }

  # make ID
  $raw_data{'ID'} ||= sprintf '%s_%s_%s/%s', $raw_data{'CHROM'}, $start, $ref, $alt;

  # create one row from each CSQ data field
  while (m/CSQ\=(.+?)(\;|$|\s)/g) {
    foreach my $csq (split '\,', $1) {
      $csq =~ s/\&/\,/g;

      my @csq_split = split '\|', $csq;
      my %new_data  = map { $csq_headers->[$_] => $csq_split[$_] } 0..$#csq_split;
      my %data      = map { exists $new_data{$_} ? ($_ => $new_data{$_}) : ($_ => $raw_data{$_}) } @$combined_headers;

      push @rows, \%data;
    }
  }

  # if no CSQ data field found, return the raw data as a row
  push @rows, \%raw_data unless @rows;

  return \@rows;
}

sub _parse_headers {
  ## @private
  my ($self, $header_lines) = @_;

  my (@combined_headers, @headers, @csq_headers, %descriptions);

  # fields we don't want for combined headers
  my %exclude_fields = map { $_ => 1 } qw(CHROM POS REF ALT INFO QUAL FILTER);

  for (reverse @$header_lines) {

    if (!@csq_headers && m/^##/ && m/INFO\=\<ID\=CSQ/) {
      m/Format\: (.+?)\"/;
      @csq_headers = split '\|', $1;

    } elsif (!@headers && s/^#//) {

      @headers = split /\s+/;

      # don't include anything after the INFO field
      $_ eq 'INFO' and last or $exclude_fields{$_} = 1 for reverse @headers;
    }

    # other headers, could be plugin descriptions
    elsif(s/^#+//) {
      m/(.+?)\=(.+)/;
      my ($key, $value) = ($1, $2);

      # remove "file /path/to/file"
      $value =~ s/ file .+$//;

      $descriptions{$key} = $value;
    }
  }

  # exclude all unwanted fields from combined headers
  @combined_headers = grep !$exclude_fields{$_}, @headers, @csq_headers;
  splice @combined_headers, 1, 0, 'Location';

  return { 'combined' => \@combined_headers, 'headers' => \@headers, 'csq' => \@csq_headers, 'descriptions' => \%descriptions };
}

1;
