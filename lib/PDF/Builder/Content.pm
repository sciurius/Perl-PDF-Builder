package PDF::Builder::Content;

use base 'PDF::Builder::Basic::PDF::Dict';

use strict;
no warnings qw( deprecated recursion uninitialized );

# VERSION
my $LAST_UPDATE = '3.003'; # manually update whenever code is changed

use Carp;
use Compress::Zlib qw();
use Encode;
use Math::Trig;    # CAUTION: deg2rad(0) = deg2rad(360) = 0!
use List::Util    qw(min max);
use PDF::Builder::Matrix;

use PDF::Builder::Basic::PDF::Utils;
use PDF::Builder::Util;
use PDF::Builder::Content::Text;

# unless otherwise noted, routines beginning with _ are internal helper 
# functions and should not be used by others
#
=head1 NAME

PDF::Builder::Content - Methods for adding graphics and text to a PDF

=head1 SYNOPSIS

    # Start with a PDF page (new or opened)
    my $pdf = PDF::Builder->new();
    my $page = $pdf->page();

    # Add new content object(s)
    my $content = $page->gfx();
    #   and/or (as separate object name)
    my $content = $page->text();

    # Then call the methods below to add graphics and text to the page.
    # Note that negative coordinates can have unpredictable effects, so
    # keep your coordinates non-negative!

=head1 METHODS

All public methods listed, I<except as otherwise noted,> return C<$self>.

=cut

sub new {
    my ($class) = @_;

    my $self = $class->SUPER::new(@_);
    $self->{' stream'}         = '';
    $self->{' poststream'}     = '';
    $self->{' font'}           = undef;
    $self->{' fontset'}        = 0;
    $self->{' fontsize'}       = 0;
    $self->{' charspace'}      = 0;
    $self->{' hscale'}         = 100;
    $self->{' wordspace'}      = 0;
    $self->{' lead'}           = 0;
    $self->{' rise'}           = 0;
    $self->{' render'}         = 0;
    $self->{' matrix'}         = [1,0,0,1,0,0];
    $self->{' textmatrix'}     = [1,0,0,1,0,0];
    $self->{' textlinematrix'} = [0,0];
    $self->{' fillcolor'}      = [0];
    $self->{' strokecolor'}    = [0];
    $self->{' translate'}      = [0,0];
    $self->{' scale'}          = [1,1];
    $self->{' skew'}           = [0,0];
    $self->{' rotate'}         = 0;
    $self->{' linewidth'}      = 1;      # see also gs LW
    $self->{' linecap'}        = 0;      # see also gs LC
    $self->{' linejoin'}       = 0;      # see also gs LJ
    $self->{' miterlimit'}     = 10;     # see also gs ML
    $self->{' linedash'}       = [[],0]; # see also gs D
    $self->{' flatness'}       = 1;      # see also gs FL
    $self->{' apiistext'}      = 0;

    return $self;
}

# internal helper method
sub outobjdeep {
    my $self = shift;

    $self->textend();
    foreach my $k (qw[ api apipdf apiistext apipage font fontset fontsize
                       charspace hscale wordspace lead rise render matrix
                       textmatrix textlinematrix fillcolor strokecolor
                       translate scale skew rotate ]) {
        $self->{" $k"} = undef;
        delete($self->{" $k"});
    }
    if ($self->{'-docompress'} == 1 && $self->{'Filter'}) {
        $self->{' stream'} = Compress::Zlib::compress($self->{' stream'});
        $self->{' nofilt'} = 1;
        delete $self->{'-docompress'};
    }
    $self->SUPER::outobjdeep(@_);
}

=head2 Coordinate Transformations

The methods in this section change the coordinate system for the
current content object relative to the rest of the document.
B<Note:> the changes are relative to the I<original> page coordinates (and 
thus, absolute), not to the previous position! Thus, C<translate(10, 10); 
translate(10, 10);> ends up only moving the origin to C<[10, 10]>, rather than 
to C<[20, 20]>. There is one call, C<transform_rel()>, which makes your changes 
I<relative> to the previous position.

If you call more than one of these methods, the PDF specification
recommends calling them in the following order: translate, rotate,
scale, skew.  Each change builds on the last, and you can get
unexpected results when calling them in a different order.

B<CAUTION:> a I<text> object ($content) behaves a bit differently. Individual
translate, rotate, scale, and skew calls I<cancel out> any previous settings.
If you want to combine multiple transformations for text, use the C<transform>
call.

=over

=item $content->translate($dx,$dy)

Moves the origin along the x and y axes by 
C<$dx> and C<$dy> respectively.

=cut

sub _translate {
    my ($x,$y) = @_;

    return (1,0,0,1, $x,$y);
}

# transform in turn calls _translate
sub translate {
    my ($self, $x,$y) = @_;

    $self->transform(-translate => [$x,$y]);

    return $self;
}

=item $content->rotate($degrees)

Rotates the coordinate system counter-clockwise (anti-clockwise) around the
current origin. Use a negative argument to rotate clockwise. Note that 360 
degrees will be treated as 0 degrees.

=cut

sub _rotate {
    my ($deg) = @_;

    return (cos(deg2rad($deg)), sin(deg2rad($deg)), -sin(deg2rad($deg)), cos(deg2rad($deg)), 0,0);
}

# transform in turn calls _rotate
sub rotate {
    my ($self, $deg) = @_;

    $self->transform(-rotate => $deg);

    return $self;
}

=item $content->scale($sx,$sy)

Scales (stretches) the coordinate systems along the x and y axes.
Separate multipliers are provided for x and y.

=cut

sub _scale {
    my ($sx,$sy) = @_;

    return ($sx,0,0,$sy, 0,0);
}

# transform in turn calls _scale
sub scale {
    my ($self, $sx,$sy) = @_;

    $self->transform(-scale => [$sx,$sy]);

    return $self;
}

=item $content->skew($skx,$sky)

Skews the coordinate system by C<$skx> degrees 
(counter-clockwise/anti-clockwise) from
the x axis I<and> C<$sky> degrees (clockwise) from the y axis.
Note that 360 degrees will be treated the same as 0 degrees.

=cut

sub _skew {
    my ($skx,$sky) = @_;

    return (1, tan(deg2rad($skx)), tan(deg2rad($sky)), 1, 0,0);
}

# transform in turn calls _skew
sub skew {
    my ($self, $skx,$sky) = @_;

    $self->transform(-skew => [$skx,$sky]);

    return $self;
}

=item $content->transform(%opts)

Use one or more of the given %opts:

    $content->transform(
        -translate => [$dx,$dy],
        -rotate    => $degrees,
        -scale     => [$sx,$sy],
        -skew      => [$skx,$sky],
        -matrix    => [$a, $b, $c, $d, $e, $f],
        -point     => [$x,$y]
    )

A six element list may be given (C<-matrix>) for a 
further transformation matrix:

    $a = cos(rot) * scale factor for X 
    $b = sin(rot) * tan(skew for X)
    $c = -sin(rot) * tan(skew for Y)
    $d = cos(rot) * scale factor for Y 
    $e = translation for X
    $f = translation for Y

Performs multiple coordinate transformations at once, in the order
recommended by the PDF specification (translate, rotate, scale, skew).
This is equivalent to making each transformation separately, I<in the
indicated order>.
A matrix of 6 values may also be given (C<-matrix>). The transformation matrix 
is updated. 
A C<-point> may be given (a point to be multiplied [transformed] by the 
completed matrix).

=cut

sub _transform {
    my (%opts) = @_;

    # start with "no-op" identity matrix
    my $mtx = PDF::Builder::Matrix->new([1,0,0], [0,1,0], [0,0,1]);
    # note order of operations, compared to PDF spec
    foreach my $o (qw( -matrix -skew -scale -rotate -translate )) {
        next unless defined $opts{$o};

        if      ($o eq '-translate') {
            my @mx = _translate(@{$opts{$o}});
            $mtx = $mtx->multiply(PDF::Builder::Matrix->new(
                [$mx[0],$mx[1],0],
                [$mx[2],$mx[3],0],
                [$mx[4],$mx[5],1]
            ));
        } elsif ($o eq '-rotate') {
            my @mx = _rotate($opts{$o});
            $mtx = $mtx->multiply(PDF::Builder::Matrix->new(
                [$mx[0],$mx[1],0],
                [$mx[2],$mx[3],0],
                [$mx[4],$mx[5],1]
            ));
        } elsif ($o eq '-scale') {
            my @mx = _scale(@{$opts{$o}});
            $mtx = $mtx->multiply(PDF::Builder::Matrix->new(
                [$mx[0],$mx[1],0],
                [$mx[2],$mx[3],0],
                [$mx[4],$mx[5],1]
            ));
        } elsif ($o eq '-skew') {
            my @mx = _skew(@{$opts{$o}});
            $mtx = $mtx->multiply(PDF::Builder::Matrix->new(
                [$mx[0],$mx[1],0],
                [$mx[2],$mx[3],0],
                [$mx[4],$mx[5],1]
            ));
        } elsif ($o eq '-matrix') {
            my @mx = @{$opts{$o}};  # no check that 6 elements given
            $mtx = $mtx->multiply(PDF::Builder::Matrix->new(
                [$mx[0],$mx[1],0],
                [$mx[2],$mx[3],0],
                [$mx[4],$mx[5],1]
            ));
        }
    }
    if ($opts{'-point'}) {
        my $mp = PDF::Builder::Matrix->new([$opts{'-point'}->[0], $opts{'-point'}->[1], 1]);
        $mp = $mp->multiply($mtx);
        return ($mp->[0][0], $mp->[0][1]);
    }

    # if not -point
    return (
        $mtx->[0][0],$mtx->[0][1],
        $mtx->[1][0],$mtx->[1][1],
        $mtx->[2][0],$mtx->[2][1]
    );
}

sub transform {
    my ($self, %opts) = @_;

    # includes -point and -matrix operations
    $self->matrix(_transform(%opts));

    if ($opts{'-translate'}) {
        @{$self->{' translate'}} = @{$opts{'-translate'}};
    } else {
        @{$self->{' translate'}} = (0,0);
    }

    if ($opts{'-rotate'}) {
        $self->{' rotate'} = $opts{'-rotate'};
    } else {
        $self->{' rotate'} = 0;
    }

    if ($opts{'-scale'}) {
        @{$self->{' scale'}} = @{$opts{'-scale'}};
    } else {
        @{$self->{' scale'}} = (1,1);
    }

    if ($opts{'-skew'}) {
        @{$self->{' skew'}} = @{$opts{'-skew'}};
    } else {
        @{$self->{' skew'}} = (0,0);
    }

    return $self;
}

=item $content->transform_rel(%opts)

Makes transformations similarly to C<transform>, except that it I<adds>
to the previously set values, rather than I<replacing> them (except for 
I<scale>, which B<multiplies> the new values with the old).

Unlike C<transform>, C<-matrix> and C<-point> are not supported.

=cut

sub transform_rel {
    my ($self, %opts) = @_;

    my ($sa1,$sb1) = @{$opts{'-skew'} ? $opts{'-skew'} : [0,0]};
    my ($sa0,$sb0) = @{$self->{" skew"}};

    my ($sx1,$sy1) = @{$opts{'-scale'} ? $opts{'-scale'} : [1,1]};
    my ($sx0,$sy0) = @{$self->{" scale"}};

    my $rot1 = $opts{'-rotate'} || 0;
    my $rot0 = $self->{" rotate"};

    my ($tx1,$ty1) = @{$opts{'-translate'} ? $opts{'-translate'} : [0,0]};
    my ($tx0,$ty0) = @{$self->{" translate"}};

    $self->transform(
        -skew      => [$sa0+$sa1, $sb0+$sb1],
        -scale     => [$sx0*$sx1, $sy0*$sy1],
        -rotate    => $rot0+$rot1,
        -translate => [$tx0+$tx1, $ty0+$ty1]
    );

    return $self;
}

=item $content->matrix($a, $b, $c, $d, $e, $f)

I<(Advanced)> Sets the current transformation matrix manually. Unless
you have a particular need to enter transformations manually, you
should use the C<transform> method instead.

 $a = cos(rot) * scale factor for X 
 $b = sin(rot) * tan(skew for X)
 $c = -sin(rot) * tan(skew for Y)
 $d = cos(rot) * scale factor for Y 
 $e = translation for X
 $f = translation for Y

In text mode, the text matrix is B<returned>. 
In graphics mode, C<$self> is B<returned>.

=cut

sub _matrix_text {
    my ($a, $b, $c, $d, $e, $f) = @_;

    return (floats($a, $b, $c, $d, $e, $f), 'Tm');
}

sub _matrix_gfx {
    my ($a, $b, $c, $d, $e, $f) = @_;

    return (floats($a, $b, $c, $d, $e, $f), 'cm');
}

# internal helper method
sub matrix_update {
    my ($self, $tx,$ty) = @_;

    $self->{' textlinematrix'}->[0] += $tx;
    $self->{' textlinematrix'}->[1] += $ty;
    return $self;
}

sub matrix {
    my ($self, $a, $b, $c, $d, $e, $f) = @_;

    if (defined $a) {
        if ($self->_in_text_object()) {
            $self->add(_matrix_text($a, $b, $c, $d, $e, $f));
            @{$self->{' textmatrix'}} = ($a, $b, $c, $d, $e, $f);
            @{$self->{' textlinematrix'}} = (0,0);
        } else {
            $self->add(_matrix_gfx($a, $b, $c, $d, $e, $f));
        }
    }
    if ($self->_in_text_object()) {
        return @{$self->{' textmatrix'}};
    } else {
        return $self;
    }
}

=back

=head2 Graphics State Parameters

The following calls also affect the B<text> state.

=over

=item $content->linewidth($width)

Sets the width of the stroke. This is the line drawn in graphics mode, or the 
I<outline> of a character in text mode (with appropriate C<render> mode).
If no C<$width> is given, the current setting is B<returned>. If the width is
being set, C<$self> is B<returned> so that calls may be chained.

=cut

sub _linewidth {
    my ($linewidth) = @_;

    return ($linewidth, 'w');
}

sub linewidth {
    my ($self, $linewidth) = @_;

    if (!defined $linewidth) {
	return $self->{' linewidth'};
    }
    $self->add(_linewidth($linewidth));
    $self->{' linewidth'} = $linewidth;

    return $self;
}

=item $content->linecap($style)

Sets the style to be used at the end of a stroke. This applies to lines
which come to a free-floating end, I<not> to "joins" ("corners") in 
polylines (see C<linejoin>).

=over

=item 0 = Butt Cap

The stroke ends at the end of the path, with no projection.

=item 1 = Round Cap

A semicircular arc is drawn around the end of the path with a diameter equal to
the line width, and is filled in.

=item 2 = Projecting Square Cap

The stroke continues past the end of the path for half the line width.

=back

If no C<$style> is given, the current setting is B<returned>. If the style is
being set, C<$self> is B<returned> so that calls may be chained.

=cut

sub _linecap {
    my ($linecap) = @_;

    return ($linecap, 'J');
}

sub linecap {
    my ($self, $linecap) = @_;

    if (!defined $linecap) {
	return $self->{' linecap'};
    }
    $self->add(_linecap($linecap));
    $self->{' linecap'} = $linecap;

    return $self;
}

=item $content->linejoin($style)

Sets the style of join to be used at corners of a path
(within a multisegment polyline).

=over

=item 0 = Miter Join

The outer edges of the strokes extend until they meet, up to the limit
specified by I<miterlimit>. If the limit would be surpassed, a I<bevel> join
is used instead. For a given linewidth, the more acute the angle is (closer
to 0 degrees), the higher the ratio of miter length to linewidth will be, and 
that's what I<miterlimit> controls.

=item 1 = Round Join

A filled circle with a diameter equal to the I<linewidth> is drawn around the
corner point, producing a rounded corner. The arc will meet up with the sides
of the line in a smooth tangent.

=item 2 = Bevel Join

A filled triangle is drawn to fill in the notch between the two strokes.

=back

If no C<$style> is given, the current setting is B<returned>. If the style is
being set, C<$self> is B<returned> so that calls may be chained.

=cut

sub _linejoin {
    my ($style) = @_;

    return ($style, 'j');
}

sub linejoin {
    my ($self, $style) = @_;

    if (!defined $style) {
	return $self->{' linejoin'};
    }
    $self->add(_linejoin($style));
    $self->{' linejoin'} = $style;

    return $self;
}

=item $content->miterlimit($ratio)

Sets the miter limit when the line join style is a I<miter> join.

The ratio is the maximum length of the miter (inner to outer corner) divided 
by the line width. Any miter above this ratio will be converted to a I<bevel> 
join. The practical effect is that lines meeting at shallow
angles are chopped off instead of producing long pointed corners.

The default miter limit is 10.0 (approximately 11.5 degree cutoff angle).

If no C<$ratio> is given, the current setting is B<returned>. If the ratio is
being set, C<$self> is B<returned> so that calls may be chained.

B<Note:> This was originally misnamed as I<meterlimit>. That name is deprecated
and will be removed some time in the future, so you should change any usage in
your code from C<meterlimit> to C<miterlimit>.

=cut

sub _miterlimit {
    my ($ratio) = @_;

    return ($ratio, 'M');
}

sub miterlimit {
    my ($self, $ratio) = @_;

    if (!defined $ratio) {
	return $self->{' miterlimit'};
    }
    $self->add(_miterlimit($ratio));
    $self->{' miterlimit'} = $ratio;

    return $self;
}

# Deprecated: miterlimit was originally named incorrectly
sub  meterlimit { 
    warn "Use miterlimit instead of meterlimit";
    return  miterlimit(@_);
}
sub _meterlimit { 
    warn "Use _miterlimit instead of _meterlimit";
    return _miterlimit(@_) 
}

=item $content->linedash()

=item $content->linedash($length)

=item $content->linedash($dash_length, $gap_length, ...)

=item $content->linedash(-pattern => [$dash_length, $gap_length, ...], -shift => $offset)

Sets the line dash pattern.

If called without any arguments, a solid line will be drawn.

If called with one argument, the dashes and gaps (strokes and
spaces) will have equal lengths.

If called with two or more arguments, the arguments represent
alternating dash and gap lengths.

If called with a hash of arguments, the I<-pattern> array may have one or
more elements, specifying the dash and gap lengths. 
A dash phase may be set (I<-shift>), which is a B<positive integer>
specifying the distance into the pattern at which to start the dashed line.
If you are using I<-full> or I<-clear> hash entries, please be aware that
they have been B<deprecated> and will be removed. Use the I<-pattern> array
instead. Note that if you wish to give a I<shift> amount, using C<-shift>,
you need to use C<-pattern> instead of one or two elements.

If an B<odd> number of dash array elements are given, the list is repeated by 
the reader software to form an even number of elements (pairs). 

If a single argument of B<-1> is given, the current setting is B<returned>. 
This is an array consisting of two elements: an anonymous array containing the 
dash pattern (default: empty), and the shift (offset) amount (default: 0). 
If the dash pattern is being I<set>, C<$self> is B<returned> so that calls may 
be chained.

=cut

sub _linedash {
    my ($self, @pat) = @_;

    unless (scalar @pat) {  # no args
        $self->{' linedash'} = [[],0];
        return ('[', ']', '0', 'd');
    } else {
        if ($pat[0] =~ /^\-/) {
            my %pat = @pat;

            # Deprecated: the -full and -clear options will be removed in a future release
	    if (defined $pat{'-full'} || defined $pat{'-clear'}) {
		warn "Use of -full and -clear in linedash is deprecated. Use -pattern.";
	    }
            $pat{'-pattern'} = [$pat{'-full'} || 0, $pat{'-clear'} || 0] unless exists $pat{'-pattern'};

            $self->{' linedash'} = [[@{$pat{'-pattern'}}],($pat{'-shift'} || 0)];
            return ('[', floats(@{$pat{'-pattern'}}), ']', ($pat{'-shift'} || 0), 'd');
        } else {
            $self->{' linedash'} = [[@pat],0];
            return ('[', floats(@pat), '] 0 d');
        }
    }
}

sub linedash {
    my ($self, @pat) = @_;

    if (scalar @pat == 1 && $pat[0] == -1) {
	return @{$self->{' linedash'}};
    }
    $self->add($self->_linedash(@pat));

    return $self;
}

=item $content->flatness($tolerance)

I<(Advanced)> Sets the maximum variation in output pixels when drawing
curves.

If no C<$tolerance> is given, the current setting is B<returned>. If the 
tolerance is being set, C<$self> is B<returned> so that calls may be chained.

=cut

sub _flatness {
    my ($tolerance) = @_;

    return ($tolerance, 'i');
}

sub flatness {
    my ($self, $tolerance) = @_;

    if (!defined $tolerance) {
	return $self->{' flatness'};
    }
    $self->add(_flatness($tolerance));
    $self->{' flatness'} = $tolerance;

    return $self;
}

=item $content->egstate($object)

I<(Advanced)> Adds an Extended Graphic State B<object> containing additional
state parameters.

=cut

sub egstate {
    my ($self, $egs) = @_;

    $self->add('/' . $egs->name(), 'gs');
    $self->resource('ExtGState', $egs->name(), $egs);

    return $self;
}

=back

=head2 Path Construction (Drawing)

=over

=item $content->move($x,$y)

Starts a new path at the specified coordinates.
Note that multiple x,y pairs I<can> be given, although this isn't that useful
(only the last pair would have an effect).

=cut

sub _move {
    my ($x,$y) = @_;

    return (floats($x,$y), 'm');
}

sub move {
    my ($self) = shift;

    my ($x,$y);
    while (defined($x = shift)) {
        $y = shift;
        $self->{' x'}  = $x;
        $self->{' y'}  = $y;
        $self->{' mx'} = $x;
        $self->{' my'} = $y;
        if ($self->_in_text_object()) {
            $self->add_post(floats($x,$y), 'm');
        } else {
            $self->add(floats($x,$y), 'm');
        }
    }

    return $self;
}

=item $content->close()

Closes and ends the current path by extending a line from the current
position to the starting position.

=cut

sub close {
    my ($self) = shift;

    $self->add('h');
    $self->{' x'} = $self->{' mx'};
    $self->{' y'} = $self->{' my'};

    return $self;
}

=item $content->endpath()

Ends the current path without explicitly enclosing it.
That is, unlike C<close>, there is B<no> line segment 
drawn back to the starting position.

=cut

sub endpath {
    my ($self) = shift;

    $self->add('n');

    return $self;
}

=back

=head3 Straight line constructs

B<Note:> None of these will actually be I<visible> until you call C<stroke> or 
C<fill>. They are merely setting up the path to draw.

=over

=item $content->line($x,$y)

=item $content->line($x,$y, $x2,$y2,...)

Extends the path in a line from the I<current> coordinates to the
specified coordinates, and updates the current position to be the new
coordinates.

Multiple additional C<[$x,$y]> pairs are permitted, to draw joined multiple 
line segments. Note that this is B<not> equivalent to a polyline (see C<poly>),
because the first C<[$x,$y]> pair in a polyline is a I<move> operation.
Also, the C<linecap> setting will be used rather than the C<linejoin>
setting for treating the ends of segments.

=cut

sub _line {
    my ($x,$y) = @_;

    return (floats($x,$y), 'l');
}

sub line {
    my ($self) = shift;

    my ($x,$y);
    while (defined($x = shift)) {
        $y = shift;
        $self->{' x'} = $x;
        $self->{' y'} = $y;
        if ($self->_in_text_object()) {
            $self->add_post(floats($x,$y), 'l');
        } else {
            $self->add(floats($x,$y), 'l');
        }
    }

    return $self;
}

=item $content->hline($x)

=item $content->vline($y)

Shortcuts for drawing horizontal and vertical lines from the current
position. They are like C<line()>, but to the new x and current y (C<hline>),
or to the the current x and new y (C<vline>).

=cut

sub hline {
    my ($self, $x) = @_;

    if ($self->_in_text_object()) {
        $self->add_post(floats($x, $self->{' y'}), 'l');
    } else {
        $self->add(floats($x, $self->{' y'}), 'l');
    }
    $self->{' x'} = $x;

    return $self;
}

sub vline {
    my ($self, $y) = @_;

    if ($self->_in_text_object()) {
        $self->add_post(floats($self->{' x'}, $y), 'l');
    } else {
        $self->add(floats($self->{' x'}, $y), 'l');
    }
    $self->{' y'} = $y;

    return $self;
}

=item $content->poly($x1,$y1, ..., $xn,$yn)

This is a shortcut for creating a polyline path. It moves to C<[$x1,$y1]>, and
then extends the path in line segments along the specified coordinates.
The current position is changed to the last C<[$x,$y]> pair given.

The difference between a polyline and a C<line> with multiple C<[$x,$y]>
pairs is that the first pair in a polyline are a I<move>, while in a line
they are a I<draw>.
Also, C<linejoin> instead of C<linecap> is used to control the appearance
of the ends of line segments.

=cut

sub poly {
    # not implemented as self,x,y = @_, as @_ must be shifted
    my ($self) = shift;
    my $x      = shift;
    my $y      = shift;

    $self->move($x,$y);
    $self->line(@_);

    return $self;
}

=item $content->rect($x,$y, $w,$h)

=item $content->rect($x1,$y1, $w1,$h1, ..., $xn,$yn, $wn,$hn)

This creates paths for one or more rectangles, with their lower left points
at C<[$x,$y]> and specified widths (+x direction) and heights (+y direction). 
Negative widths and heights are permitted, which draw to the left (-x) and 
below (-y) the given corner point, respectively. 
The current position is changed to the C<[$x,$y]> of the last rectangle given.
Note that this is the I<starting> point of the rectangle, not the end point.

=cut

sub rect {
    my $self = shift;

    my ($x,$y, $w,$h);
    while (defined($x = shift)) {
        $y = shift;
        $w = shift;
        $h = shift;
        $self->add(floats($x,$y, $w,$h), 're');
    }
    $self->{' x'} = $x;
    $self->{' y'} = $y;

    return $self;
}

=item $content->rectxy($x1,$y1, $x2,$y2)

This creates a rectangular path, with C<[$x1,$y1]> and C<[$x2,$y2]>
specifying I<opposite> corners. They can be Lower Left and Upper Right,
I<or> Upper Left and Lower Right, in either order, so long as they are
diagonally opposite each other. 
The current position is changed to the C<[$x1,$y1]> (first) pair.

=cut

# TBD allow multiple rectangles, as in rect()

sub rectxy {
    my ($self, $x,$y, $x2,$y2) = @_;

    $self->rect($x,$y, ($x2-$x),($y2-$y));

    return $self;
}

=back

=head3 Curved line constructs

B<Note:> None of these will actually be I<visible> until you call C<stroke> or 
C<fill>. They are merely setting up the path to draw.

=over

=item $content->circle($xc,$yc, $radius)

This creates a circular path centered on C<[$xc,$yc]> with the specified
radius. It does B<not> change the current position.

=cut

sub circle {
    my ($self, $xc,$yc, $r) = @_;

    $self->arc($xc,$yc, $r,$r, 0,360, 1);
    $self->close();

    return $self;
}

=item $content->ellipse($xc,$yc, $rx,$ry)

This creates a closed elliptical path centered on C<[$xc,$yc]>, with axis radii
(semidiameters) specified by C<$rx> (x axis) and C<$ry> (y axis), respectively.
It does not change the current position.

=cut

sub ellipse {
    my ($self, $xc,$yc, $rx,$ry) = @_;

    $self->arc($xc,$yc, $rx,$ry, 0,360, 1);
    $self->close();

    return $self;
}

# input: x and y axis radii
#        sweep start and end angles
#        sweep direction (0=CCW (default), or 1=CW)
# output: two endpoints and two control points for
#           the Bezier curve describing the arc
# maximum 30 degrees of sweep: is broken up into smaller
#   arc segments if necessary
# if crosses 0 degree angle in either sweep direction, split there at 0
# if alpha=beta (0 degree sweep) or either radius <= 0, fatal error
sub _arctocurve {
    my ($rx,$ry, $alpha,$beta, $dir) = @_;

    if (!defined $dir) { $dir = 0; }  # default is CCW sweep
    # check for non-positive radius
    if ($rx <= 0 || $ry <= 0) {
	die "curve request with radius not > 0 ($rx, $ry)";
    }
    # check for zero degrees of sweep
    if ($alpha == $beta) {
	die "curve request with zero degrees of sweep ($alpha to $beta)";
    }

    # constrain alpha and beta to 0..360 range so 0 crossing check works
    while ($alpha < 0.0)   { $alpha += 360.0; }
    while ( $beta < 0.0)   {  $beta += 360.0; }
    while ($alpha > 360.0) { $alpha -= 360.0; }
    while ($beta > 360.0) { $beta -= 360.0; }

    # Note that there is a problem with the original code, when the 0 degree
    # angle is crossed. It especially shows up in arc() and pie(). Therefore, 
    # split the original sweep at 0 degrees, if it crosses that angle.
    if (!$dir && $alpha > $beta) { # CCW pass over 0 degrees
      if      ($alpha == 360.0 && $beta == 0.0) { # oddball case
        return (_arctocurve($rx,$ry, 0.0,360.0, 0));
      } elsif ($alpha == 360.0) { # alpha to 360 would be null
        return (_arctocurve($rx,$ry, 0.0,$beta, 0));
      } elsif ($beta == 0.0) { # 0 to beta would be null
        return (_arctocurve($rx,$ry, $alpha,360.0, 0));
      } else {
        return (
            _arctocurve($rx,$ry, $alpha,360.0, 0),
            _arctocurve($rx,$ry, 0.0,$beta, 0)
        );
      }
    }
    if ($dir && $alpha < $beta) { # CW pass over 0 degrees
      if      ($alpha == 0.0 && $beta == 360.0) { # oddball case
        return (_arctocurve($rx,$ry, 360.0,0.0, 1));
      } elsif ($alpha == 0.0) { # alpha to 0 would be null
        return (_arctocurve($rx,$ry, 360.0,$beta, 1));
      } elsif ($beta == 360.0) { # 360 to beta would be null
        return (_arctocurve($rx,$ry, $alpha,0.0, 1));
      } else {
        return (
            _arctocurve($rx,$ry, $alpha,0.0, 1),
            _arctocurve($rx,$ry, 360.0,$beta, 1)
        );
      }
    }

    # limit arc length to 30 degrees, for reasonable smoothness
    # none of the long arcs or short resulting arcs cross 0 degrees
    if (abs($beta-$alpha) > 30) {
        return (
            _arctocurve($rx,$ry, $alpha,($beta+$alpha)/2, $dir),
            _arctocurve($rx,$ry, ($beta+$alpha)/2,$beta, $dir)
        );
    } else {
       # Note that we can't use deg2rad(), because closed arcs (circle() and 
       # ellipse()) are 0-360 degrees, which deg2rad treats as 0-0 radians!
        $alpha = ($alpha * pi / 180);
        $beta  = ($beta * pi / 180);

        my $bcp = (4.0/3 * (1 - cos(($beta - $alpha)/2)) / sin(($beta - $alpha)/2));
        my $sin_alpha = sin($alpha);
        my $sin_beta  = sin($beta);
        my $cos_alpha = cos($alpha);
        my $cos_beta  = cos($beta);

        my $p0_x = $rx * $cos_alpha;
        my $p0_y = $ry * $sin_alpha;
        my $p1_x = $rx * ($cos_alpha - $bcp * $sin_alpha);
        my $p1_y = $ry * ($sin_alpha + $bcp * $cos_alpha);
        my $p2_x = $rx * ($cos_beta  + $bcp * $sin_beta);
        my $p2_y = $ry * ($sin_beta  - $bcp * $cos_beta);
        my $p3_x = $rx * $cos_beta;
        my $p3_y = $ry * $sin_beta;

        return ($p0_x,$p0_y, $p1_x,$p1_y, $p2_x,$p2_y, $p3_x,$p3_y);
    }
}

=item $content->arc($xc,$yc, $rx,$ry, $alpha,$beta, $move, $dir)

=item $content->arc($xc,$yc, $rx,$ry, $alpha,$beta, $move)

This extends the path along an arc of an ellipse centered at C<[$xc,$yc]>.
The semidiameters of the elliptical curve are C<$rx> (x axis) and C<$ry> 
(y axis), respectively, and the arc sweeps from C<$alpha> degrees to C<$beta>
degrees. The current position is then set to the endpoint of the arc.

Set C<$move> to a I<true> value if this arc is the beginning of a new
path instead of the continuation of an existing path. Either way, the 
current position will be updated to the end of the arc.
Use C<$rx == $ry> for a circular arc.

The optional C<$dir> arc sweep direction defaults to 0 (I<false>), for a
counter-clockwise/anti-clockwise sweep. Set to 1 (I<true>) for a clockwise
sweep.

=cut

sub arc {
    my ($self, $xc,$yc, $rx,$ry, $alpha,$beta, $move, $dir) = @_;

    if (!defined $dir) { $dir = 0; }
    my @points = _arctocurve($rx,$ry, $alpha,$beta, $dir);
    my ($p0_x,$p0_y, $p1_x,$p1_y, $p2_x,$p2_y, $p3_x,$p3_y);

    $p0_x = $xc + shift @points;
    $p0_y = $yc + shift @points;

    $self->move($p0_x,$p0_y) if $move;

    while (scalar @points > 0) {
        $p1_x = $xc + shift @points;
        $p1_y = $yc + shift @points;
        $p2_x = $xc + shift @points;
        $p2_y = $yc + shift @points;
        $p3_x = $xc + shift @points;
        $p3_y = $yc + shift @points;
        $self->curve($p1_x,$p1_y, $p2_x,$p2_y, $p3_x,$p3_y);
        shift @points;
        shift @points;
        $self->{' x'} = $p3_x;
        $self->{' y'} = $p3_y;
    }

    return $self;
}

=item $content->pie($xc,$yc, $rx,$ry, $alpha,$beta, $dir)

=item $content->pie($xc,$yc, $rx,$ry, $alpha,$beta)

Creates a pie-shaped path from an ellipse centered on C<[$xc,$yc]>.
The x-axis and y-axis semidiameters of the ellipse are C<$rx> and C<$ry>,
respectively, and the arc sweeps from C<$alpha> degrees to C<$beta>
degrees. 
It does not change the current position.
Depending on the sweep angles and direction, this can draw either the
pie "slice" or the remaining pie (with slice removed).
Use C<$rx == $ry> for a circular pie.
Use a different C<[$xc,$yc]> for the slice, to offset it from the remaining pie.

The optional C<$dir> arc sweep direction defaults to 0 (I<false>), for a
counter-clockwise/anti-clockwise sweep. Set to 1 (I<true>) for a clockwise
sweep.

This is a shortcut to draw a section of elliptical (or circular) arc and
connect it to the center of the ellipse or circle, to form a pie shape.

=cut

sub pie {
    my ($self, $xc,$yc, $rx,$ry, $alpha,$beta, $dir) = @_;

    if (!defined $dir) { $dir = 0; }
    my ($p0_x,$p0_y) = _arctocurve($rx,$ry, $alpha,$beta, $dir);
    $self->move($xc,$yc);
    $self->line($p0_x+$xc, $p0_y+$yc);
    $self->arc($xc,$yc, $rx,$ry, $alpha,$beta, 0, $dir);
    $self->close();

    return $self;
}

=item $content->curve($cx1,$cy1, $cx2,$cy2, $x,$y)

This extends the path in a curve from the current point to C<[$x,$y]>,
using the two specified I<control> points to create a cubic Bezier curve, and
updates the current position to be the new point (C<[$x,$y]>).

Within a B<text> object, the text's baseline follows the Bezier curve.

Note that while multiple sets of three C<[x,y]> pairs are permitted, these
are treated as I<independent> cubic Bezier curves. There is no attempt made to
smoothly blend one curve into the next!

=cut

sub curve {
    my ($self) = shift;

    my ($cx1,$cy1, $cx2,$cy2, $x,$y);
    while (defined($cx1 = shift)) {
        $cy1 = shift;
        $cx2 = shift;
        $cy2 = shift;
        $x   = shift;
        $y   = shift;
        if ($self->_in_text_object()) {
            $self->add_post(floats($cx1,$cy1, $cx2,$cy2, $x,$y), 'c');
        } else {
            $self->add(floats($cx1,$cy1, $cx2,$cy2, $x,$y), 'c');
        }
        $self->{' x'} = $x;
        $self->{' y'} = $y;
    }

    return $self;
}

=item $content->spline($cx1,$cy1, $x,$y)

This extends the path in a curve from the current point to C<[$x,$y]>,
using the two specified points to create a spline, and updates the
current position to be the new point.

Internally, these splines are cubic Bezier curves (see C<curve>) with the 
two control points synthesized from the two given points.

Note that while multiple sets of two C<[x,y]> pairs are permitted, these
are treated as I<independent> splines. There is no attempt made to
smoothly blend one spline into the next!

Further note that this "spline" may not match a common definition of
a spline being a curve passing I<through> B<all> the given points! It is a
piecewise cubic Bezier curve. Use with care, and do not make assumptions about
splines for you or your readers.

=cut

# TBD consider a cspline() call for a cubic spline that DOES pass through all points

sub spline {
    my ($self) = shift;

    while (scalar @_ >= 4) {
        my $cx = shift;
        my $cy = shift;
        my $x = shift;
        my $y = shift;
        my $c1x = (2*$cx + $self->{' x'})/3;
        my $c1y = (2*$cy + $self->{' y'})/3;
        my $c2x = (2*$cx + $x)/3;
        my $c2y = (2*$cy + $y)/3;
        $self->curve($c1x,$c1y, $c2x,$c2y, $x,$y);
    }

    return $self;
}

=item $content->bogen($x1,$y1, $x2,$y2, $radius, $move, $larger, $reverse)

(German for I<bow>, as in a segment (arc) of a circle. This is a segment
of a circle defined by the intersection of two circles of a given radius, 
with the two intersection points as inputs. There are four possible resulting
arcs, which can be selected with C<$larger> and C<$reverse>.)

This extends the path along an arc of a circle of the specified radius
between C<[$x1,$y1]> to C<[$x2,$y2]>. The current position is then set
to the endpoint of the arc (C<[$x2,$y2]>).

Set C<$move> to a I<true> value if this arc is the beginning of a new
path instead of the continuation of an existing path. Note that this 
(C<$move> = I<false>) is
I<not> a straight line to I<P1> and then the arc, but a blending into the curve
from the current point. It will often I<not> pass through I<P1>!

Set C<$larger> to a I<true> value to draw the larger ("outer") arc between the 
two points, instead of the smaller one. Both arcs are
drawn I<clockwise> from I<P1> to I<P2>.

Set C<$reverse> to a I<true> value to draw the mirror image of the
specified arc (flip it over, so that its center point is on the other
side of the line connecting the two points). Both arcs are drawn
I<counter-clockwise> from I<P1> to I<P2>.

The C<$radius> value cannot be smaller than B<half> the distance from 
C<[$x1,$y1]> to C<[$x2,$y2]>. If it is too small, the radius will be set to
half the distance between the points (resulting in an arc that is a
semicircle). This is a silent error.

=cut

sub bogen {
    my ($self, $x1,$y1, $x2,$y2, $r, $move, $larc, $spf) = @_;

    my ($p0_x,$p0_y, $p1_x,$p1_y, $p2_x,$p2_y, $p3_x,$p3_y);
    my ($dx,$dy, $x,$y, $alpha,$beta, $alpha_rad, $d,$z, $dir, @points);

    if ($x1 == $x2 && $y1 == $y2) {
        die "bogen requires two distinct points";
    }
    if ($r <= 0.0) {
        die "bogen requires a positive radius";
    }

    $dx = $x2 - $x1;
    $dy = $y2 - $y1;
    $z = sqrt($dx**2 + $dy**2);
    $alpha_rad = asin($dy/$z); # |dy/z| guaranteed <= 1.0
    $alpha_rad = pi - $alpha_rad if $dx < 0;

    # alpha is direction of vector P1 to P2
    $alpha = rad2deg($alpha_rad);
    # use the complementary angle for flipped arc (arc center on other side)
    # effectively clockwise draw from P2 to P1
    $alpha -= 180 if $spf;

    $d = 2*$r;
    # z/d must be no greater than 1.0 (arcsine arg)
    if ($z > $d) { 
        $d = $z;  # SILENT error and fixup
        $r = $d/2;
    }

    $beta = rad2deg(2*asin($z/$d));
    # beta is the sweep P1 to P2: ~0 (r very large) to 180 degrees (min r)
    $beta = 360-$beta if $larc;  # large arc is remainder of small arc
    # for large arc, beta could approach 360 degrees if r is very large

    # always draw CW (dir=1)
    # note that start and end could be well out of +/-360 degree range
    @points = _arctocurve($r,$r, 90+$alpha+$beta/2,90+$alpha-$beta/2, 1);

    if ($spf) {  # flip order of points for reverse arc
        my @pts = @points;
        @points = ();
        while (scalar @pts) {
            $y = pop @pts;
            $x = pop @pts;
            push(@points, $x,$y);
        }
    }

    $p0_x = shift @points;
    $p0_y = shift @points;
    $x = $x1 - $p0_x;
    $y = $y1 - $p0_y;

    $self->move($x1,$y1) if $move;

    while (scalar @points > 0) {
        $p1_x = $x + shift @points;
        $p1_y = $y + shift @points;
        $p2_x = $x + shift @points;
        $p2_y = $y + shift @points;
        # if we run out of data points, use the end point instead
        if (scalar @points == 0) {
            $p3_x = $x2;
            $p3_y = $y2;
        } else {
            $p3_x = $x + shift @points;
            $p3_y = $y + shift @points;
        }
        $self->curve($p1_x,$p1_y, $p2_x,$p2_y, $p3_x,$p3_y);
        shift @points;
        shift @points;
    }

    return $self;
}

=back

=head2 Path Painting (Drawing)

=over

=item $content->stroke()

Strokes the current path.

=cut

sub _stroke {
    return 'S';
}

sub stroke {
    my ($self) = shift;

    $self->add(_stroke());

    return $self;
}

=item $content->fill($use_even_odd_fill)

Fill the current path's enclosed I<area>. 
It does I<not> stroke the enclosing path around the area.

If the path intersects with itself, the nonzero winding rule will be
used to determine which part of the path is filled in. This basically
fills in I<everything> inside the path. If you would prefer to use
the even-odd rule, pass a I<true> argument. This basically will fill
alternating closed sub-areas.

See the PDF Specification, section 8.5.3.3, for more details on
filling.

=cut

sub fill {
    my ($self) = shift;

    $self->add(shift() ? 'f*' : 'f');

    return $self;
}

=item $content->fillstroke($use_even_odd_fill)

Fill the enclosed area and then stroke the current path.

=cut

sub fillstroke {
    my ($self) = shift;

    $self->add(shift() ? 'B*' : 'B');

    return $self;
}

=item $content->clip($use_even_odd_fill)

Modifies the current clipping path by intersecting it with the current
path.

=cut

sub clip {
    my ($self) = shift;

    $self->add(shift() ? 'W*' : 'W');

    return $self;
}

=back

=head2 Colors

=over

=item $content->fillcolor($color)

=item $content->strokecolor($color)

Sets the fill (enclosed area) or stroke (path) color. The interior of text
characters are I<filled>, and (if ordered by C<render>) the outline is
I<stroked>.

    # Use a named color
    # -> RGB color model
    # there are many hundreds of named colors defined in 
    # PDF::Builder::Resource::Colors
    $content->fillcolor('blue');

    # Use an RGB color (# followed by 3, 6, 9, or 12 hex digits)
    # -> RGB color model
    # This maps to 0-1.0 values for red, green, and blue
    $content->fillcolor('#FF0000');   # red

    # Use a CMYK color (% followed by 4, 8, 12, or 16 hex digits)
    # -> CMYK color model
    # This maps to 0-1.0 values for cyan, magenta, yellow, and black
    $content->fillcolor('%FF000000');   # cyan

    # Use an HSV color (! followed by 3, 6, 9, or 12 hex digits)
    # -> RGB color model
    # This maps to 0-360 degrees for the hue, and 0-1.0 values for 
    # saturation and value
    $content->fillcolor('!FF0000');

    # Use an HSL color (& followed by 3, 6, 9, or 12 hex digits)
    # -> L*a*b color model
    # This maps to 0-360 degrees for the hue, and 0-1.0 values for 
    # saturation and lightness. Note that 360 degrees = 0 degrees (wraps)
    $content->fillcolor('&FF0000');

    # Use an L*a*b color ($ followed by 3, 6, 9, or 12 hex digits)
    # -> L*a*b color model
    # This maps to 0-100 for L, -100 to 100 for a and b
    $content->fillcolor('$FF0000');

In all cases, if too few digits are given, the given digits
are silently right-padded with 0's (zeros). If an incorrect number 
of digits are given, the next lowest number of expected
digits are used, and the remaining digits are silently ignored.

    # A single number between 0.0 (black) and 1.0 (white) is an alternate way
    # of specifying a gray scale.
    $content->fillcolor(0.5);

    # Three array elements between 0.0 and 1.0 is an alternate way of specifying
    # an RGB color.
    $content->fillcolor(0.3, 0.59, 0.11);

    # Four array elements between 0.0 and 1.0 is an alternate way of specifying
    # a CMYK color.
    $content->fillcolor(0.1, 0.9, 0.3, 1.0);

In all cases, if a number is less than 0, it is silently turned into a 0. If
a number is greater than 1, it is silently turned into a 1. This "clamps" all
values to the range 0.0-1.0.

    # A single reference is treated as a pattern or shading space.

    # Two or more entries with the first element a Perl reference, is treated 
    # as either an indexed colorspace reference plus color-index(es), or 
    # as a custom colorspace reference plus parameter(s).

If no value was passed in, the current fill color (or stroke color) I<array> 
is B<returned>, otherwise C<$self> is B<returned>.

=cut

# TBD document in POD (examples) and add t tests for (pattern/shading space, 
#     indexed colorspace + color-index, or custom colorspace + parameter)
#     for both fillcolor() and strokecolor(). t/cs-webcolor.t does test 
#     cs + index

# note that namecolor* routines all handle #, %, !, &, and named
# colors, even though _makecolor only sends each type to proper
# routine. reserved for different output color models?

# I would have preferred to move _makecolor and _clamp over to Util.pm, but
# some subtle errors were showing up. Maybe in the future...
sub _makecolor {
    my ($self, $sf, @clr) = @_;

    # $sf is the stroke/fill flag (0/1)
    # note that a scalar argument is turned into a single element array
    # there will be at least one element, guaranteed

    if      (scalar @clr == 1) {  # a single @clr element
        if      (ref($clr[0])) {
            # pattern or shading space
            return '/Pattern', ($sf? 'cs': 'CS'), '/'.($clr[0]->name()), ($sf? 'scn': 'SCN');
    
        } elsif ($clr[0] =~ m/^[a-z#!]/i) {
            # colorname (alpha) or # (RGB) or ! (HSV) specifier and 3/6/9/12 digits
            # with rgb target colorspace
            # namecolor always returns an RGB
            return namecolor($clr[0]), ($sf? 'rg': 'RG');
    
        } elsif ($clr[0] =~ m/^%/) {
            # % (CMYK) specifier and 4/8/12/16 digits
            # with cmyk target colorspace
            return namecolor_cmyk($clr[0]), ($sf? 'k': 'K');

        } elsif ($clr[0] =~ m/^[\$\&]/) {
            # & (HSL) or $ (L*a*b) specifier
            # with L*a*b target colorspace
            if (!defined $self->resource('ColorSpace', 'LabS')) {
                my $dc = PDFDict();
                my $cs = PDFArray(PDFName('Lab'), $dc);
                $dc->{'WhitePoint'} = PDFArray(map { PDFNum($_) } qw(1 1 1));
                $dc->{'Range'} = PDFArray(map { PDFNum($_) } qw(-128 127 -128 127));
                $dc->{'Gamma'} = PDFArray(map { PDFNum($_) } qw(2.2 2.2 2.2));
                $self->resource('ColorSpace', 'LabS', $cs);
            }
            return '/LabS', ($sf? 'cs': 'CS'), namecolor_lab($clr[0]), ($sf? 'sc': 'SC');

        } else { # should be a float number... add a test and else failure?
            # grey color spec.
            $clr[0] = _clamp($clr[0], 0, 0, 1);
            return $clr[0], ($sf? 'g': 'G');

       #} else {
       #    die 'invalid color specification.';
        } # @clr 1 element

    } elsif (scalar @clr > 1) {  # 2 or more @clr elements
        if      (ref($clr[0])) {
            # indexed colorspace plus color-index(es)
            # or custom colorspace plus param(s)
            my $cs = shift @clr;
            return '/'.$cs->name(), ($sf? 'cs': 'CS'), $cs->param(@clr), ($sf? 'sc': 'SC');

       # What exactly is the difference between the following case and the 
       # previous case? The previous allows multiple indices or parameters and
       # this one doesn't. Also, this one would try to process a bad call like
       # fillcolor('blue', 'gray').
       #} elsif (scalar @clr == 2) {
       #    # indexed colorspace plus color-index
       #    # or custom colorspace plus param
       #    return '/'.$clr[0]->name(), ($sf? 'cs': 'CS'), $clr[0]->param($clr[1]), ($sf? 'sc': 'SC');

        } elsif (scalar @clr == 3) {
            # legacy rgb color-spec (0 <= x <= 1)
            $clr[0] = _clamp($clr[0], 0, 0, 1);
            $clr[1] = _clamp($clr[1], 0, 0, 1);
            $clr[2] = _clamp($clr[2], 0, 0, 1);
            return floats($clr[0], $clr[1], $clr[2]), ($sf? 'rg': 'RG');

        } elsif (scalar @clr == 4) {
            # legacy cmyk color-spec (0 <= x <= 1)
            $clr[0] = _clamp($clr[0], 0, 0, 1);
            $clr[1] = _clamp($clr[1], 0, 0, 1);
            $clr[2] = _clamp($clr[2], 0, 0, 1);
            $clr[3] = _clamp($clr[3], 0, 0, 1);
            return floats($clr[0], $clr[1], $clr[2], $clr[3]), ($sf? 'k': 'K');

        } else {
            die 'invalid color specification.';
        } # @clr with 2 or more elements

    } else {  # @clr with 0 elements. presumably won't see...
        die 'invalid color specification.';
    }
}

# silent error if non-numeric value (assign default), 
# or outside of min..max limits (clamp to closer limit).
sub _clamp {
    my ($val, $default, $min, $max) = @_;

    if (!Scalar::Util::looks_like_number($val)) { $val = $default; }
    if      ($val < $min) { 
        $val = $min; 
    } elsif ($val > $max) {
        $val = $max;
    }

    return $val;
}

sub _fillcolor {
    my ($self, @clrs) = @_;

    if      (ref($clrs[0]) =~ m|^PDF::Builder::Resource::ColorSpace|) {
        $self->resource('ColorSpace', $clrs[0]->name(), $clrs[0]);
    } elsif (ref($clrs[0]) =~ m|^PDF::Builder::Resource::Pattern|) {
        $self->resource('Pattern', $clrs[0]->name(), $clrs[0]);
    }

    return $self->_makecolor(1, @clrs);
}

sub fillcolor {
    my $self = shift;

    if (scalar @_) {
        @{$self->{' fillcolor'}} = @_;
        $self->add($self->_fillcolor(@_));

	return $self;
    } else {

        return @{$self->{' fillcolor'}};
    }
}

sub _strokecolor {
    my ($self, @clrs) = @_;

    if      (ref($clrs[0]) =~ m|^PDF::Builder::Resource::ColorSpace|) {
        $self->resource('ColorSpace', $clrs[0]->name(), $clrs[0]);
    } elsif (ref($clrs[0]) =~ m|^PDF::Builder::Resource::Pattern|) {
        $self->resource('Pattern', $clrs[0]->name(), $clrs[0]);
    }

    return $self->_makecolor(0, @clrs);
}

sub strokecolor {
    my $self = shift;

    if (scalar @_) {
        @{$self->{' strokecolor'}} = @_;
        $self->add($self->_strokecolor(@_));

	return $self;
    } else {

        return @{$self->{' strokecolor'}};
    }
}

=item $content->shade($shade, @coord)

Sets the shading matrix.

=over

=item $shade

A hash reference that includes a C<name()> method for the shade name.

=item @coord

An array of 4 items: X-translation, Y-translation, 
X-scaled and translated, Y-scaled and translated.

=back

=cut

sub shade {
    my ($self, $shade, @coord) = @_;

    my @tm = (
        $coord[2]-$coord[0] , 0,
        0                   , $coord[3]-$coord[1],
        $coord[0]           , $coord[1]
    );
    $self->save();
    $self->matrix(@tm);
    $self->add('/'.$shade->name(), 'sh');

    $self->resource('Shading', $shade->name(), $shade);
    $self->restore();

    return $self;
}

=back

=head2 External Objects

=over

=item $content->image($image_object, $x,$y, $width,$height)

=item $content->image($image_object, $x,$y, $scale)

=item $content->image($image_object, $x,$y)

    # Example
    my $image_object = $pdf->image_jpeg($my_image_file);
    $content->image($image_object, 100, 200);

Places an image on the page in the specified location (specifies the lower 
left corner of the image).

If coordinate transformations have been made (see I<Coordinate
Transformations> above), the position and scale will be relative to the
updated coordinates. Otherwise, C<[0,0]> will represent the bottom left
corner of the page, and C<$width> and C<$height> will be measured at
72dpi.

For example, if you have a 600x600 image that you would like to be
shown at 600dpi (i.e., one inch square), set the width and height to 72.
(72 Big Points is one inch)

=cut

sub image {
    my ($self, $img, $x,$y, $w,$h) = @_;

    if (defined $img->{'Metadata'}) {
        $self->_metaStart('PPAM:PlacedImage', $img->{'Metadata'});
    }
    $self->save();
    if      (!defined $w) {
        $h = $img->height();
        $w = $img->width();
    } elsif (!defined $h) {
        $h = $img->height()*$w;
        $w = $img->width()*$w;
    }
    $self->matrix($w,0,0,$h, $x,$y);
    $self->add("/".$img->name(), 'Do');
    $self->restore();
    $self->{' x'} = $x;
    $self->{' y'} = $y;
    $self->resource('XObject', $img->name(), $img);
    if (defined $img->{'Metadata'}) {
        $self->_metaEnd();
    }

    return $self;
}

=item $content->formimage($form_object, $x,$y, $scaleX, $scaleY)

=item $content->formimage($form_object, $x,$y, $scale)

=item $content->formimage($form_object, $x,$y)

Places an XObject on the page in the specified location (giving the lower
left corner of the image) and scale (applied to the image's native height
and width). If no scale is given, use 1 for both X and Y. If one scale is 
given, use for both X and Y.  If two scales given, they are for (separately) 
X and Y. In general, you should not greatly distort an image by using greatly 
different scaling factors in X and Y, although it is now possible for when 
that effect is desirable.

B<Note> that while this method is named form I<image>, it is also used for the 
psedoimages created by the barcode routines. Images are naturally dimensionless 
(1 point square) and need at some point to be scaled up to the desired point 
size. Barcodes are naturally sized in points, and should be scaled at 
approximately I<1>. Therefore, it would greatly overscale barcodes to multiply 
by image width and height I<within> C<formimage>, and require scaling of 
1/width and 1/height in the call. So, we leave scaling alone within 
C<formimage> and have the user manually scale I<images> by the image width and 
height (in pixels) in the call to C<formimage>.

=cut

sub formimage {
    my ($self, $img, $x,$y, $sx,$sy) = @_;
    # if one scale given, use for both
    # if no scale given, use 1 for both
    if (!defined $sx) { $sx = 1; }
    if (!defined $sy) { $sy = $sx; }

   ## convert to desired height and width in pixels
   #$sx *= $img->width();
   #$sy *= $img->height();

    $self->save();

    $self->matrix($sx,0,0,$sy, $x,$y);
    $self->add('/'.$img->name(), 'Do');
    $self->restore();
    $self->resource('XObject', $img->name(), $img);

    return $self;
}

=back

=head2 Text 

=head3 Text State Parameters

All of the following parameters that take a size are applied before
any scaling takes place, so you don't need to adjust values to
counteract scaling.

=over

=item $spacing = $content->charspace($spacing)

Sets additional spacing between B<characters> in a line. This is in I<points>,
and is initially zero.
It may be positive to give an I<expanded> effect to words, or
it may be negative to give a I<condensed> effect to words.
If C<$spacing> is given, the current setting is replaced by that value and
C<$self> is B<returned> (to permit chaining).
If C<$spacing> is not given, the current setting is B<returned>.

=cut

sub _charspace {
    my ($space) = @_;

    return float($space, 6) . ' Tc';
}

sub charspace {
    my ($self, $space) = @_;

    if (defined $space) {
        $self->{' charspace'} = $space;
        $self->add(_charspace($space));

	return $self;
    } else {
        return $self->{' charspace'};
    }
}

=item $spacing = $content->wordspace($spacing)

Sets additional spacing between B<words> in a line. This is in I<points> and
is initially zero 
(i.e., just the width of the space, without anything extra). It may be negative
to close up sentences a bit. 
If C<$spacing> is given, the current setting is replaced by that value and
C<$self> is B<returned> (to permit chaining).
If C<$spacing> is not given, the current setting is B<returned>.

Note that it is a limitation of the PDF specification (as of version 1.7, 
section 9.3.3) that only spacing with an ASCII space (x20) is adjusted. Neither
required blanks (xA0) nor any multiple-byte spaces (including thin and wide
spaces) are currently adjusted.

=cut

sub _wordspace {
    my ($space) = @_;

    return float($space, 6) . ' Tw';
}

sub wordspace {
    my ($self, $space) = @_;

    if (defined $space) {
        $self->{' wordspace'} = $space;
        $self->add(_wordspace($space));

	return $self;
    } else {
        return $self->{' wordspace'};
    }
}

=item $scale = $content->hscale($scale)

Sets the percentage of horizontal text scaling (relative sizing, I<not> 
spacing). This is initally 100 (percent, i.e., no scaling). A scale of greater 
than 100 will stretch the text, while less than 100 will compress it.
If C<$scale> is given, the current setting is replaced by that value and
C<$self> is B<returned> (to permit chaining).
If C<$scale> is not given, the current setting is B<returned>.

Note that scaling affects all of the character widths, interletter spacing, and
interword spacing. It is inadvisable to stretch or compress text by a large 
amount, as it will quickly make the text unreadable. If your objective is to 
justify text, you will usually be better off using C<charspace> and C<wordspace>
to expand (or slightly condense) a line to fill a desired width. Also see 
the C<text_justify()> calls for this purpose.

B<Note:> This was originally misnamed as I<hspace> (it is a horizontal 
I<scaling factor>, not an amount of horizontal I<space>). That name is 
deprecated and will be removed some time in the future, so you should change 
any usage in your code from C<hspace> to C<hscale>.

=cut

sub _hscale {
    my ($scale) = @_;

    return float($scale, 6) . ' Tz';
}

sub hscale {
    my ($self, $scale) = @_;

    if (defined $scale) {
        $self->{' hscale'} = $scale;
        $self->add(_hscale($scale));

	return $self;
    } else {
        return $self->{' hscale'};
    }
}

# Deprecated: hscale was originally named incorrectly (as hspace)
sub  hspace { 
    warn "Use hscale instead of hspace";
    return  hscale(@_); 
}
sub _hspace { 
    warn "Use _hscale instead of _hspace";
    return _hscale(@_); 
}
# note that the private class data ' hspace' is no longer supported

=item $leading = $content->lead($leading)

Sets the text leading, which is the distance between baselines. This
is initially B<zero> (i.e., the lines will be printed on top of each
other). The unit of leading is points.
If C<$leading> is given, the current setting is replaced by that value and
C<$self> is B<returned> (to permit chaining).
If C<$leading> is not given, the current setting is B<returned>.

=cut

sub _lead {
    my ($leading) = @_;

    return float($leading) . ' TL';
}

sub lead {
    my ($self, $leading) = @_;

    if (defined $leading) {
        $self->{' lead'} = $leading;
        $self->add(_lead($leading));

	return $self;
    } else {
        return $self->{' lead'};
    }
}

=item $mode = $content->render($mode)

Sets the text rendering mode.

=over

=item 0 = Fill text

=item 1 = Stroke text (outline)

=item 2 = Fill, then stroke text

=item 3 = Neither fill nor stroke text (invisible)

=item 4 = Fill text and add to path for clipping

=item 5 = Stroke text and add to path for clipping

=item 6 = Fill, then stroke text and add to path for clipping

=item 7 = Add text to path for clipping

=back

If C<$mode> is given, the current setting is replaced by that value and
C<$self> is B<returned> (to permit chaining).
If C<$mode> is not given, the current setting is B<returned>.

=cut

sub _render {
    my ($mode) = @_;

    return intg($mode) . ' Tr';
}

sub render {
    my ($self, $mode) = @_;

    if (defined $mode) {
        $mode = max(0, min(7, int($mode))); # restrict to integer range 0..7
        $self->{' render'} = $mode;
        $self->add(_render($mode));

        return $self;
    } else {
        return $self->{' render'};
    }
}

=item $dist = $content->rise($dist)

Adjusts the baseline up or down from its current location.  This is
initially zero. A C<$dist> greater than 0 moves the baseline B<up> the page
(y increases).

Use this for creating superscripts or subscripts (usually along with an
adjustment to the font size).
If C<$dist> is given, the current setting is replaced by that value and
C<$self> is B<returned> (to permit chaining).
If C<$dist> is not given, the current setting is B<returned>.

=cut

sub _rise {
    my ($dist) = @_;

    return float($dist) . ' Ts';
}

sub rise {
    my ($self, $dist) = @_;

    if (defined $dist) {
        $self->{' rise'} = $dist;
        $self->add(_rise($dist));

	return $self;
    } else {
        return $self->{' rise'};
    }
}

=item %state = $content->textstate(charspace => $value, wordspace => $value, ...)

This is a shortcut for setting multiple text state parameters at once.
If any parameters are set, an I<empty> hash is B<returned>.
This can also be used without arguments to retrieve the current text
state settings (a hash of the state is B<returned>).

B<Note:> This does not work with the C<save> and C<restore> commands.

=cut

sub textstate {
    my ($self) = shift;

    my %state;
    if (scalar @_) {
        %state = @_;
        foreach my $k (qw( charspace hscale wordspace lead rise render )) {
            next unless $state{$k};
            $self->can($k)->($self, $state{$k});
        }
        if ($state{'font'} && $state{'fontsize'}) {
            $self->font($state{'font'}, $state{'fontsize'});
        }
        if ($state{'textmatrix'}) {
            $self->matrix(@{$state{'textmatrix'}});
            @{$self->{' translate'}} = @{$state{'translate'}};
            $self->{' rotate'} = $state{'rotate'};
            @{$self->{' scale'}} = @{$state{'scale'}};
            @{$self->{' skew'}} = @{$state{'skew'}};
        }
        if ($state{'fillcolor'}) {
            $self->fillcolor(@{$state{'fillcolor'}});
        }
        if ($state{'strokecolor'}) {
            $self->strokecolor(@{$state{'strokecolor'}});
        }
        %state = ();
    } else {
        foreach my $k (qw( font fontsize charspace hscale wordspace lead rise render )) {
            $state{$k}=$self->{" $k"};
        }
        $state{'matrix'}         = [@{$self->{" matrix"}}];
        $state{'textmatrix'}     = [@{$self->{" textmatrix"}}];
        $state{'textlinematrix'} = [@{$self->{" textlinematrix"}}];
        $state{'rotate'}         = $self->{" rotate"};
        $state{'scale'}          = [@{$self->{" scale"}}];
        $state{'skew'}           = [@{$self->{" skew"}}];
        $state{'translate'}      = [@{$self->{" translate"}}];
        $state{'fillcolor'}      = [@{$self->{" fillcolor"}}];
        $state{'strokecolor'}    = [@{$self->{" strokecolor"}}];
    }

    return %state;
}

=item $content->font($font_object, $size)

Sets the font and font size.

    # Example (12 point Helvetica)
    my $pdf = PDF::Builder->new();
    my $fontname = $pdf->corefont('Helvetica');
    $content->font($fontname, 12);

=cut

sub _font {
    my ($font, $size) = @_;

    if ($font->isvirtual() == 1) {
        return '/'.$font->fontlist()->[0]->name().' '.float($size).' Tf';
    } else {
        return '/'.$font->name().' '.float($size).' Tf';
    }
}

sub font {
    my ($self, $font, $size) = @_;

    unless ($size) {
        croak q{A font size is required};
    }
    $self->_fontset($font, $size);
    $self->add(_font($font, $size));
    $self->{' fontset'} = 1;

    return $self;
}

sub _fontset {
    my ($self, $font, $size) = @_;

    $self->{' font'} = $font;
    $self->{' fontsize'} = $size;
    $self->{' fontset'} = 0;

    if ($font->isvirtual() == 1) {
        foreach my $f (@{$font->fontlist()}) {
            $self->resource('Font', $f->name(), $f);
        }
    } else {
        $self->resource('Font', $font->name(), $font);
    }

    return $self;
}

=back

=head3 Positioning Text

=over

=item $content->distance($dx,$dy)

This moves to the start of the previously-written line, plus an offset by the 
given amounts, which are both required. C<[0,0]> would overwrite the previous 
line, while C<[0,36]> would place the new line 36pt I<above> the old line 
(higher y). The C<$dx> moves to the right, if positive.

C<distance> is analogous to graphic's C<move>, except that it is relative to
the beginning of the previous text write, not to the coordinate origin.
B<Note> that subsequent text writes will be relative to this new starting
(left) point and Y position! E.g., if you give a non-zero C<$dx>, subsequent
lines will be indented by that amount.

=cut

sub distance {
    my ($self, $dx,$dy) = @_;

    $self->add(float($dx), float($dy), 'Td');
    $self->matrix_update($dx,$dy);
    $self->{' textlinematrix'}->[0] = $dx;

    return $self;
}

=item $content->cr()

=item $content->cr($vertical_offset)

=item $content->cr(0)

If passed without an argument, moves (down) to the start of the I<next> line 
(distance set by C<lead>). This is similar to C<nl()>.

If passed I<with> an argument, the C<lead> distance is ignored and the next 
line starts that far I<up> the page (positive value) or I<down> the page 
(negative value) from the current line. "Y" increases upward, so a negative
value would normally be used to get to the next line down.

An argument of I<0> would
simply return to the start of the present line, overprinting it with new text.
That is, it acts as a simple carriage return, without a linefeed.

=cut

sub cr {
    my ($self, $offset) = @_;

    if (defined $offset) {
        $self->add(0, float($offset), 'Td');
        $self->matrix_update(0, $offset);
    } else {
        $self->add('T*');
        $self->matrix_update(0, $self->lead() * -1);
    }
    $self->{' textlinematrix'}->[0] = 0;

    return $self;
}

=item $content->nl()

=item $content->nl($indent)

=item $content->nl(0)

Moves to the start of the next line (see C<lead>). If C<$indent> is not given,
or is 0, there is no indentation. Otherwise, indent by that amount (I<out>dent
if a negative value). The unit of measure is hundredths of a "unit of text
space", or roughly 88 per em.

=cut

sub nl {
    my ($self, $indent) = @_;

    # can't use Td, because it permanently changes the line start by $indent
    # same problem using the distance() call
    $self->add('T*');  # go to start of next line
    $self->matrix_update(0, $self->lead() * -1);
    $self->{' textlinematrix'}->[0] = 0;
    if (defined($indent) && $indent != 0) {
	# move right or left by $indent
	$self->add('[' . (-10 * $indent) . '] TJ');
    }

    return $self;
}

=item ($tx,$ty) = $content->textpos()

B<Returns> the current text position on the page (where next write will happen) 
as an array.

B<Note:> This does not affect the PDF in any way. It only tells you where the
the next write will occur.

=cut

sub _textpos {
    my ($self, @xy) = @_;

    my ($x,$y) = (0,0);
    while (scalar @xy > 0) {
        $x += shift @xy;
        $y += shift @xy;
    }
    my @m = _transform(
        -matrix => $self->{" textmatrix"},
        -point  => [$x,$y]
    );
    return ($m[0],$m[1]);
}

sub _textpos2 {
    my ($self) = shift;

    return (@{$self->{" textlinematrix"}});
}

sub textpos {
    my ($self) = shift;

    return ($self->_textpos(@{$self->{" textlinematrix"}}));
}

=item $width = $content->advancewidth($string, %opts)

=item $width = $content->advancewidth($string)

Options %opts:

=over

=item font => $f3_TimesRoman

Change the font used, overriding $self->{' font'}. The font must have been
previously created (i.e., is not the name). Example: use Times-Roman.

=item fontsize => 12

Change the font size, overriding $self->{' fontsize'}. Example: 12 pt font.

=item wordspace => 0.8

Change the additional word spacing, overriding $self->wordspace(). 
Example: add 0.8 pt between words.

=item charspace => -2.1

Change the additional character spacing, overriding $self->charspace(). 
Example: subtract 2.1 pt between letters, to condense the text.

=item hscale => 125

Change the horizontal scaling factor, overriding $self->hscale(). 
Example: stretch text to 125% of its natural width.

=back

B<Returns> the B<width of the $string> based on all currently set text-state
attributes. These can optionally be overridden with %opts. I<Note that these
values temporarily B<replace> the existing values, B<not> scaling them up or
down.> For example, if the existing charspace is 2, and you give in options
a value of 3, the value used is 3, not 5.

B<Note:> This does not affect the PDF in any way. It only tells you how much
horizontal space a text string will take up.

=cut

sub advancewidth {
    my ($self, $text, %opts) = @_;

    my ($k, $glyph_width, $num_space, $num_char, $word_spaces,
	$char_spaces, $advance);

    return 0 unless defined($text) and length($text);
    # fill %opts from current settings unless explicitly given
    foreach $k (qw[ font fontsize wordspace charspace hscale]) {
        $opts{$k} = $self->{" $k"} unless defined $opts{$k};
    }
    # any other options given are ignored

    $glyph_width = $opts{'font'}->width($text)*$opts{'fontsize'};
    $num_space   = $text =~ y/\x20/\x20/;
    $num_char    = length($text);
    $word_spaces = $opts{'wordspace'}*$num_space;
    $char_spaces = $opts{'charspace'}*($num_char - 1);
    $advance     = ($glyph_width+$word_spaces+$char_spaces)*$opts{'hscale'}/100;

    return $advance;
}

=back

=head3 Rendering Text

=over 

=back

=head4 Single Lines

=over

=item $width = $content->text($text, %opts)

=item $width = $content->text($text)

Adds text to the page (left justified). 
The width used (in points) is B<returned>.

Options:

=over

=item -indent => $distance

Indents the text by the number of points (A value less than 0 gives an
I<outdent>.

=item -underline => 'auto'

=item -underline => $distance

=item -underline => [$distance, $thickness, ...]

Underlines the text. C<$distance> is the number of units beneath the
baseline, and C<$thickness> is the width of the line.
Multiple underlines can be made by passing several distances and
thicknesses.

Example:
 
    # 3 underlines:
    #   distance 4, thickness 1, color red
    #   distance 7, thickness 1.5, color yellow
    #   distance 11, thickness 2, color (strokecolor default)
    -underline=>[4,[1,'red'],7,[1.5,'yellow'],11,2],

=back

=cut

sub _text_underline {
    my ($self, $xy1,$xy2, $underline, $color) = @_;

    $color ||= 'black';
    my @underline = ();
    if (ref($underline) eq 'ARRAY') {
        @underline = @{$underline};
    } else {
        @underline = ($underline, 1);
    }
    push @underline,1 if @underline%2;

    my $underlineposition = (-$self->{' font'}->underlineposition()*$self->{' fontsize'}/1000||1);
    my $underlinethickness = ($self->{' font'}->underlinethickness()*$self->{' fontsize'}/1000||1);
    my $pos = 1;

    while (@underline) {
        $self->add_post(_save());

        my $distance = shift @underline;
        my $thickness = shift @underline;
        my $scolor = $color;
        if (ref $thickness) {
            ($thickness, $scolor) = @{$thickness};
        }

        if ($distance eq 'auto') {
            $distance = $pos*$underlineposition;
        }
        if ($thickness eq 'auto') {
            $thickness = $underlinethickness;
        }

        my ($x1,$y1) = $self->_textpos(@{$xy1}, 0, -($distance+($thickness/2)));
        my ($x2,$y2) = $self->_textpos(@{$xy2}, 0, -($distance+($thickness/2)));

        $self->add_post($self->_strokecolor($scolor));
        $self->add_post(_linewidth($thickness));
        $self->add_post(_move($x1,$y1));
        $self->add_post(_line($x2,$y2));
        $self->add_post(_stroke);

        $self->add_post(_restore());
        $pos++;
    }
}

sub text {
    my ($self, $text, %opts) = @_;

    my $wd = 0;
    if ($self->{' fontset'} == 0) {
        unless (defined($self->{' font'}) and $self->{' fontsize'}) {
            croak q{Can't add text without first setting a font and font size};
        }
        $self->font($self->{' font'}, $self->{' fontsize'});
        $self->{' fontset'} = 1;
    }
    if (defined $opts{'-indent'}) {
        $wd += $opts{'-indent'};
        $self->matrix_update($wd, 0);
    }
    my $ulxy1 = [$self->_textpos2()];

    if (defined $opts{'-indent'}) {
    # changed for Acrobat 8 and possibly others
    #    $self->add('[', (-$opts{'-indent'}*(1000/$self->{' fontsize'})*(100/$self->hscale())), ']', 'TJ');
        $self->add($self->{' font'}->text($text, $self->{' fontsize'}, (-$opts{'-indent'}*(1000/$self->{' fontsize'})*(100/$self->hscale()))));
    } else {
        $self->add($self->{' font'}->text($text, $self->{' fontsize'}));
    }

    $wd = $self->advancewidth($text);
    $self->matrix_update($wd, 0);

    my $ulxy2 = [$self->_textpos2()];

    if (defined $opts{'-underline'}) {
        $self->_text_underline($ulxy1,$ulxy2, $opts{'-underline'}, $opts{'-strokecolor'});
    }

    return $wd;
}

sub _metaStart {
    my ($self, $tag, $obj) = @_;

    $self->add("/$tag");
    if (defined $obj) {
        my $dict = PDFDict();
        $dict->{'Metadata'} = $obj;
        $self->resource('Properties', $obj->name(), $dict);
        $self->add('/'.($obj->name()));
        $self->add('BDC');
    } else {
        $self->add('BMC');
    }
    return $self;
}

sub _metaEnd {
    my ($self) = shift;

    $self->add('EMC');
    return $self;
}

=back

=head2 Advanced Methods

=over

=item $content->save()

Saves the current I<graphics> state on a PDF stack. See PDF definition 8.4.2 
through 8.4.4 for details. This includes the line width, the line cap style, 
line join style, miter limit, line dash pattern, stroke color, fill color,
current transformation matrix, current clipping port, flatness, and dictname.
This method applies to both I<text> and I<gfx> objects.

=cut
#Currently, this method is a no-op for PDF::Builder I<text> objects.
#

# 8.4.1 Table 52 Graphics State Parameters (device independent) -----------
# current transformation matrix*, current clipping path*, current color space,
# current color*, TEXT painting parameters (see 9.3), line width*%, line cap*%,
# line join*%, miter limit*%, dash pattern*%, rendering intent%, stroke adjust%,
# blend mode%, soft mask, alpha constant%, alpha source%
# 8.4.1 Table 53 Graphics State Parameters (device dependent) -------------
# overprint%, overprint mode%, black generation%, undercolor removal%, 
# transfer%, halftone%, flatness*%, smoothness%
# 9.3 Table 104 Text State Parameters -------------------------------------
# character spacing+, word spacing+, horizontal scaling+, leading+, text font+, 
# text font size+, text rendering mode+, text rise+, text knockout%
#  * saved on graphics state stack
#  + now saved on graphics state stack since save/restore enabled for text
#  % see ExtGState.pm for setting as extended graphics state

sub _save {
    return 'q';
}

sub save {
    my ($self) = shift;

   #unless ($self->_in_text_object()) {
        $self->add(_save());
   #}

   return $self;
}

=item $content->restore()

Restores the most recently saved graphics state (see C<save>),
removing it from the stack. You cannot I<restore> the graphics state (pop it off
the stack) unless you have done at least one I<save> (pushed it on the stack).
This method applies to both I<text> and I<gfx> objects.

=cut
#Currently, this method is a no-op for PDF::Builder I<text> objects.
#

sub _restore {
    return 'Q';
}

sub restore {
    my ($self) = shift;

   #unless ($self->_in_text_object()) {
        $self->add(_restore());
   #}

   return $self;
}

=item $content->add(@content)

Add raw content to the PDF stream. You will generally want to use the
other methods in this class instead.

=cut

sub add_post {
    my ($self) = shift;

    if (scalar @_) {
       $self->{' poststream'} .= ($self->{' poststream'} =~ m|\s$|o ? '' : ' ') . join(' ', @_) . ' ';
    }

    return $self;
}

sub add {
    my $self = shift;

    if (scalar @_) {
       $self->{' stream'} .= encode('iso-8859-1', ($self->{' stream'} =~ m|\s$|o ? '' : ' ') . join(' ', @_) . ' ');
    }

    return $self;
}

# Shortcut method for determining if we're inside a text object
# (i.e., between BT and ET). See textstart() and textend().
sub _in_text_object {
    my ($self) = shift;

    return defined($self->{' apiistext'}) && $self->{' apiistext'} == 1;
}

=item $content->compressFlate()

Marks content for compression on output.  This is done automatically
in nearly all cases, so you shouldn't need to call this yourself.

=cut

sub compressFlate {
    my $self = shift;

    $self->{'Filter'} = PDFArray(PDFName('FlateDecode'));
    $self->{'-docompress'} = 1;

    return $self;
}

=item $content->textstart()

Starts a text object. You will likely want to use the C<text> method
(text context, not text output) instead.

=cut

sub textstart {
    my ($self) = @_;

    unless ($self->_in_text_object()) {
        $self->add(' BT ');
        $self->{' apiistext'}         = 1;
        $self->{' font'}              = undef;
        $self->{' fontset'}           = 0;
        $self->{' fontsize'}          = 0;
        $self->{' charspace'}         = 0;
        $self->{' hscale'}            = 100;
        $self->{' wordspace'}         = 0;
        $self->{' lead'}              = 0;
        $self->{' rise'}              = 0;
        $self->{' render'}            = 0;
        @{$self->{' matrix'}}         = (1,0,0,1,0,0);
        @{$self->{' textmatrix'}}     = (1,0,0,1,0,0);
        @{$self->{' textlinematrix'}} = (0,0);
        @{$self->{' fillcolor'}}      = (0);
        @{$self->{' strokecolor'}}    = (0);
        @{$self->{' translate'}}      = (0,0);
        @{$self->{' scale'}}          = (1,1);
        @{$self->{' skew'}}           = (0,0);
        $self->{' rotate'}            = 0;
    }

    return $self;
}

=item $content->textend()

Ends a text object.

=cut

sub textend {
    my ($self) = @_;

    if ($self->_in_text_object()) {
        $self->add(' ET ', $self->{' poststream'});
        $self->{' apiistext'}  = 0;
        $self->{' poststream'} = '';
    }

    return $self;
}

=back

=cut

# helper function for many methods
sub resource {
    my ($self, $type, $key, $obj, $force) = @_;

    if ($self->{' apipage'}) {
        # we are a content stream on a page.
        return $self->{' apipage'}->resource($type, $key, $obj, $force);
    } else {
        # we are a self-contained content stream.
        $self->{'Resources'} ||= PDFDict();

        my $dict = $self->{'Resources'};
        $dict->realise() if ref($dict) =~ /Objind$/;

        $dict->{$type} ||= PDFDict();
        $dict->{$type}->realise() if ref($dict->{$type}) =~ /Objind$/;
        unless (defined $obj) {
            return $dict->{$type}->{$key} || undef;
        } else {
            if ($force) {
                $dict->{$type}->{$key} = $obj;
            } else {
                $dict->{$type}->{$key} ||= $obj;
            }
            return $dict;
        }
    }
}

1;
