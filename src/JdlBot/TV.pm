
package JdlBot::TV;

use strict;
use warnings;

use Log::Message::Simple qw(msg error);

sub checkTvMatch {
	my ( $title , $filter , $dbh ) = @_;
	my $tv_type;
	my $tv_last;
	
	# Make sure that we're working with the latest and greatest tv_last
	my $sth = $dbh->prepare('SELECT tv_last FROM filters WHERE title=? LIMIT 1');
	$sth->execute($filter->{'title'});
	if( $sth->errstr ){ return ""; }
	$filter->{'tv_last'} = ($sth->fetchall_arrayref())->[0]->[0];
	
	if ( $filter->{'tv_last'} ){
		$tv_last = determineTvType( $filter->{'tv_last'} );
		if ( ! $filter->{'new_tv_last'} ){ $filter->{'new_tv_last'} = []; }
	}
	$tv_type = determineTvType( $title );
	unless( $tv_type ){ return ""; }
	
	if ( $tv_last ){
		if ( $tv_last->{'type'} eq 's' && $tv_type->{'type'} eq 's' ){
			if ( $tv_type->{'info'}->{'s'} . $tv_type->{'info'}->{'e'} > $tv_last->{'info'}->{'s'} . $tv_last->{'info'}->{'e'} ){
				return "S" . $tv_type->{'info'}->{'s'} . "E" . $tv_type->{'info'}->{'e'};
			} else {
				return "";
			}
		} elsif ( $tv_last->{'type'} eq 'd' && $tv_type->{'type'} eq 'd' ){
			if (  $tv_type->{'info'}->{'d'} - $tv_last->{'info'}->{'d'} > 0 ) {
				return $tv_type->{'info'}->{'s'};
			} else {
				return "";
			}
		} else {
			return "";
		}
	} else {
		if ( $tv_type->{'type'} eq 's' ){
			return "S" . $tv_type->{'info'}->{'s'} . "E" . $tv_type->{'info'}->{'e'};
		} elsif ( $tv_type->{'type'} eq 'd' ) {
			return $tv_type->{'info'}->{'s'};
		}
	}
}

sub storeTvLast {
	my ($new, $title , $dbh) = @_;
	# Make sure that we're working with the latest and greatest tv_last
	my $sth = $dbh->prepare('SELECT tv_last FROM filters WHERE title=? LIMIT 1');
	$sth->execute($title);
	if( $sth->errstr ){ return 0; }
	my $old = ($sth->fetchall_arrayref())->[0]->[0];
	my $compare = 0;
	my $new_info=determineTvType($new);
	my $old_info=determineTvType($old);
	if ($new_info->{'type'} ne $old_info->{'type'}) {
		$compare = 1;
	}
	if ($new_info->{'type'} eq 'd') {
		if ($new_info->{'info'}->{'d'}>$old_info->{'info'}->{'d'}) {
			$compare = 1;
		}
	} else {
		if ("$new_info->{'info'}->{'s'}$new_info->{'info'}->{'e'}">"$old_info->{'info'}->{'s'}$old_info->{'info'}->{'e'}") {
			$compare = 1;
		}
	}
	if ($compare) {
		my $qh = $dbh->prepare('UPDATE filters SET tv_last=? WHERE title=?');
		$qh->execute( $new, $title );
		
	}
}

sub determineTvType {
	my ( $s ) = @_;
	my $tv_info = {};
	
	if ( $s =~ /s(\d{2})e(\d{2})/i ){
		$tv_info->{'type'} = 's';
		$tv_info->{'info'} = { 's' => $1, 'e' => $2 };
	} elsif ( $s =~ /(\d{4}).?(\d{2}).?(\d{2})/ ){
		$tv_info->{'type'} = 'd';
		$tv_info->{'info'} = { 'd' => "$1$2$3", 's' => "$1.$2.$3" };
	} else {
		$tv_info = undef;
	}
	
	return $tv_info;
}

1;
