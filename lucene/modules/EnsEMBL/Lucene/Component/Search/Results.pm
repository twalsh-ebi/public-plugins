# $Id$

package EnsEMBL::Lucene::Component::Search::Results;

use strict;

use URI::Escape qw(uri_escape);

use base qw(EnsEMBL::Web::Component);

sub _init {
  my $self = shift;
  $self->cacheable(0);
  $self->ajaxable(0);
}

sub content {
  my $self             = shift;
  my $hub              = $self->hub;
  my $species_defs     = $hub->species_defs;
  my $sitetype         = lc $species_defs->ENSEMBL_SITETYPE;
  my $species          = $hub->param('species');
  my $display_species  = $species eq 'all' ? sprintf('the %s website', ucfirst $sitetype) : $hub->species_defs->get_config($species,'SPECIES_COMMON_NAME');
  my $q                = uri_escape($hub->param('q'));
  my $results_by_group = $self->object->groups;
  my $html;
  
  if ($results_by_group->{'Species'}{'total'} && $results_by_group->{'Feature type'}{'total'} || $results_by_group->{'Help'}{'total'}) {
    my @group_classes = ('threecol-left', 'threecol-middle', 'threecol-right');
    my $i             = 0;
       $html          = "<h3>Your search of $display_species with '$q' returned the following results:</h3>";
    
    foreach my $group_name ('Feature type', 'Species', 'Help') {
      my $group_total = delete $results_by_group->{$group_name}->{'total'};
      
      next if $group_total < 1;
      
      my $class = $group_classes[$i];
      my $group = $results_by_group->{$group_name}->{'results'};
      
      $html .= qq{
      <div class="$class">
        <table class="search_results">
          <tr><th colspan="2">By $group_name</th></tr>
          <tr><td>Total</td><td>$group_total</td></tr>
      };

      foreach my $child_name (sort { $group->{$a}{'sort_field'} cmp $group->{$b}{'sort_field'} } keys %{$group}) {
        my $child      = $group->{$child_name};
           $child_name =~ s/${sitetype}_(.*)$/ucfirst($1)/e;
        my $display_n  = $child->{'sort_field'};
           $display_n  =~ s/${sitetype}_(.*)$/ucfirst($1)/e;
           $display_n  =~  s/_/ /g;

        $html .= qq{
          <tr>
            <td>
              <a href="#" class="collapsible">$display_n</a>
              <ul class="shut">
        };
        
        my $grandchild  = $child->{'results'};
        my $child_count = $child->{'total'};
        my $g_clipped;
        
        foreach my $g_name (sort { $grandchild->{$a}{'sort_field'} cmp $grandchild->{$b}{'sort_field'} } keys %{$grandchild}) {
          my $gchild    = $grandchild->{$g_name};
          my $display_n = $gchild->{'sort_field'};
             $display_n =~ s/${sitetype}_(.*)$/ucfirst($1)/e;
          my $g_count   = $gchild->{'count'};
          my $clipped   = $gchild->{'is_clipped_flag'};
             $g_clipped = '>' if $clipped eq '>';
             $g_name    =~ s/${sitetype}_(.*)$/ucfirst($1)/e;

          # Handle Docs Urls differently
          my $g_url;
          
          if ($g_name =~ /faq|docs|glossary|help/i) {
            $g_url = sprintf '/Search/Details?species=all;idx=%s;q=%s', ucfirst($g_name), $q;
          } else {
            my ($idx, $sp) = $group_name =~ /species/i ? ($g_name, $child_name) : ($child_name, $g_name);
            $sp     =~ s/\s/_/;
            $g_name =~ s/_/ /g;
            $g_url  = "/$sp/Search/Details?species=$sp;idx=$idx;end=$g_count;q=" . $q;
          }
          
          # yet more exceptions for Help and docs
          # change Help -> Page Help, Docs -> Documentation and Faq to FAQ
          # this should be fixed at source i.e. the Search Domain name
          $display_n =~ s/Help/Page Help/;
          $display_n =~ s/Docs/Documentation/;
          $display_n =~ s/Faq/FAQ/;
          $display_n =~ s/_/ /g;

          $html .= qq{<li><a href="$g_url"> $display_n ($clipped$g_count)</a></li>};
        }
        
        $html .= qq{
              </ul>
            </td>
            <td style="width:5em"><a href="#"> $g_clipped$child_count</a></td>
          </tr>
        };
      }

      $html .= qq{
        </table>
      </div>};
      
      $i++;
    }
  } else {
    $html = $self->re_search($q);
  }
  
  return $html;
}

sub re_search {
  my ($self, $q)      = @_;
  my $hub             = $self->hub;
  my $sitetype        = ucfirst lc $hub->species_defs->ENSEMBL_SITETYPE;
  my $species         = $hub->param('species');
  my $display_species = $species eq 'all' ? 'all species' : $hub->species_defs->get_config($species,'SPECIES_COMMON_NAME');
  
  if ($q =~ /^(\S+?)(\d+)/) {
    my $ens = $1;
    my $dig = $2;
    
    if ($ens =~ /ENS|OTT/ && length $dig != 11 && $ens !~ /ENSFM|ENSSNP/) {
      my $newq = $ens . sprintf "%011d", $dig;
      my $url  = '/' . $hub->species . "/Search/Results?species=$species;idx=" . $hub->param('idx') . ';q=' . $newq;
      
      return qq{
        <h2>Your search of $display_species with '$q' returned no results</h2>
        <h3>Would you like to <a href="$url">search using $newq</a> (note number of digits)?</h3>
      };
    }
  }
  
  if ($species ne 'all') {
    my $url = '/' . $hub->species . '/Search/Results?species=all;idx=' . $hub->param('idx') . ';q=' . $q;
    
    return qq{
      <h2>Your search of annotated features from $display_species for the term '$q' returned no results</h2>
      <h3>Would you like to search <a href="$url">the rest of the website</a> with this term?</h3>
    };
  }

  return qq{
    <h2>Your search of the $sitetype website for the term '$q' returned no results</h2>
    <h3>If you are expecting to find features with this search term and think the failure to do so is an error, please <a href="/Help/Contact" class="popup">contact helpdesk</a> and let us know</h3>
  };
}

1;

