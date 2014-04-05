use strict;
use warnings;
package App::Pipeline::Lite4::Resolver ;
use Moo;
use MooX::late;
use Ouch;
use Path::Tiny;
use Types::Path::Tiny qw/Path AbsPath/;
use YAML::Any;
use List::Util qw(max reduce);
use Data::Table;
use Data::Dumper;
use App::Pipeline::Lite4::Template::TinyMod; 
use App::Pipeline::Lite4::Util;
use Storable qw(dclone);
extends 'App::Pipeline::Lite4::Base';

has pipeline_datasource  => ( isa => 'Data::Table', is => 'rw', lazy_build =>1 );
has placeholder_hash     => ( isa =>'HashRef', is => 'rw', default => sub {return {}});
has current_run_num => ( isa => 'Num|Undef', is => 'rw');
has current_run_dir => (isa => Path, is =>'rw', lazy_build => 1);
has pipeline_step_struct => ( isa => 'HashRef' , is => 'rw', lazy_build => 1 );
has pipeline_step_struct_resolved => ( isa => 'HashRef' , is => 'rw', default => sub {{}}  );
has run_num_dep  => ( isa => 'Num|Undef', is => 'rw');
has tot_jobs => ( isa => 'Num', is => 'ro', lazy_build => 1);
#has job_filter_str  => ( isa => 'Str|Undef', is =>'rw');
has job_filter => ( isa  => 'ArrayRef|Undef', is =>'rw', lazy_build => 1 );

#has step_filter_str => ( isa => 'Str|Undef', is => 'rw'); in base
has step_filter => ( isa => 'ArrayRef|Undef' , is => 'rw', lazy_build =>1 );


sub _build_pipeline_datasource {
    my $self = shift;
    my $datasourcefile = path( $self->datasource_file )->absolute;    
    ouch 'badfile', "Need to provide datasource file location\n" unless defined( $datasourcefile);
    #my $t =  App::Pipeline::Lite2::Datasource->new( datasource_file => $datasourcefile );         
    my $t = Data::Table::fromTSV( $datasourcefile->stringify );
}

sub _build_pipeline_step_struct {
     my $self = shift;
     my $yaml = $self->pipeline_parse_file->slurp;
     return Load($yaml);   
}

sub _build_current_run_dir {
    my $self = shift;
    return  path( $self->output_dir, $self->output_run_name . ($self->current_run_num) );
}

sub _build_tot_jobs {
    my $self = shift;
    return $self->pipeline_datasource->lastRow + 1; 
}

sub _build_job_filter  {
    my $self= shift;
    if( defined $self->job_filter_str ) {
        #my @jobs_to_keep = $self->job_filter_str->split('\s+');
        #return \@jobs_to_keep;
        return $self->_parse_job_filter_str($self->job_filter_str);
    } else {
        return undef;    
    }   
}

sub _parse_job_filter_str {
    my $self = shift;
    my $job_filter_str = shift;
    my @job_filters = split ',', $job_filter_str;
    my @jobs;
    foreach my $job_filter (@job_filters){
        if($job_filter =~ '-'){
           my @pair = split '-', $job_filter;
           push @jobs, $pair[0] .. $pair[1]; 
        }else{
           push @jobs, $job_filter; 
        }
        
    } 
    return [ App::Pipeline::Lite4::Util::uniq( @jobs ) ];
}


sub _build_step_filter {
    my $self = shift;
    if( defined $self->step_filter_str ) {
        #my ($start_step, $end_step) = $self->step_filter_str =~ /([0-9]+)\-([0-9]+)/;
        my @steps;
        #if(defined($start_step) and defined($end_step)){
        #   @steps = $start_step .. $end_step;
        #   return \@steps;
        #} else {
           @steps = split '\s+', $self->step_filter_str;       
           return \@steps;
        #} 
    } else {
        return undef;    
    }
}

#does this only need to be done on a per job basis.
sub _step_filter_on_resolved_step_struct  { 
        my $self = shift;
        my $steps = $self->step_filter;
        #warn "@$steps";
        my $resolved_step_struct = $self->pipeline_step_struct_resolved;
        $self->logger->debug( "Steps to keep: @$steps\n");        
        foreach my $step_struct (values %$resolved_step_struct) {
            foreach my $step_name ( keys %$step_struct) {               
               $self->logger->debug( "Checking $step_name against filter\n" );
               
               #### WE WANT ANY####
               my $code = sub { my $k = shift; return 1 if( $step_name eq $k ); return 0;   };
               my $dont_delete = reduce { $a || $code->(local $_ = $b)  } 0,  @$steps;
               
               #delete $step_struct->{$step_name} unless any{ ($step_name eq $_) } any{ ($step_name eq $_) } @$steps; 
               #######
               
               delete $step_struct->{$step_name} unless $dont_delete; #any{ ($step_name eq $_) } @$steps;          
            }
        }       
        #the run number must be set to the last run. otherwise we could end up with dependency issues.
        #this might not be good enough, e.g. we may have run a smoke_test - this creates output directories
        #my $last_run_num = App::Pipeline::Lite1::Resolver->new( output_dir => $self->output_dir)->_last_run_number;    
        #$self->run_num($last_run_num) unless defined($self->run_num); #the user has already assigned a run number we use this
        #$self->logger->debug("Set run number to " . $self->run_num);
} 

sub _job_filter_on_resolved_step_struct   { 
     my $self=shift;
     my $jobs_to_keep= $self->job_filter;
      
     my $resolved_step_struct = $self->pipeline_step_struct_resolved;
     $self->logger->debug( "Jobs to keep: @$jobs_to_keep\n");
     foreach my $job_num (keys %$resolved_step_struct) {
         
          #### WE WANT ANY####
               my $code = sub { my $k = shift; return 1 if( $job_num eq $k ); return 0;   };
               my $dont_delete = reduce { $a || $code->(local $_ = $b)  } 0,  @$jobs_to_keep;               
          #delete $resolved_step_struct->{$job_num} unless any { ($job_num == $_) } @$jobs_to_keep;
          #######
                 
         delete $resolved_step_struct->{$job_num} unless $dont_delete;
     }
}

sub resolve {
   my $self = shift;
   # TYPE: ( Path::Class::File :$yaml_infile,  Path::Class::File :$yaml_outfile )  
   my $yaml_infile  = shift;
   my $yaml_outfile = shift;
   $self->pipeline_parse_file($yaml_infile); #sets the path to yaml file produced by parser step
   $self->_resolve;
   $yaml_outfile->spew( Dump( $self->pipeline_step_struct_resolved ) );
}

sub _resolve {
    my $self = shift;
    #$self->clear_pipeline_step_struct_resolved;    
    $self->current_run_num( $self->_last_run_number + 1 ) unless defined( $self->current_run_num);
    
    foreach my $row ( 0 .. $self->pipeline_datasource->lastRow ) {
         $self->logger->log("debug", "=== Job $row  ==="); 
         $self->_add_data_source_to_placeholder_hash( $row);
          #add input file directory to placeholder hash
         ##$self->_add_input_files_to_placeholder_hash;
         #add software to placeholder hash
         $self->_add_software_to_placeholder_hash;
         # add globals to placeholder hash      
         ##$self->_add_dir_to_placeholder_hash ( dir_name => 'global', dir_path => dir( $self->output_dir , 'run' . ($self->current_run_num) )); 
         # add data dir to placeholder hash 
         ##$self->_add_dir_to_placeholder_hash ( dir_name => 'data', dir_path => dir( $self->output_dir->parent ) );
         
         # add in the output files expected for each step to the placeholder hash       

         $self->_add_steps_in_step_struct_to_placeholder_hash($row);
         $self->_create_directory_structure_from_placeholder_hash;         
         
         # add in the output files expected for each step to the placeholder hash       
         $self->_add_expected_output_files_to_placeholder_hash( $row);
         $self->_add_expected_output_files_to_jobs_in_placeholder_hash;
      #   warn Dumper $self->placeholder_hash;
         
         
         
         # validate placeholders against placeholder hash
         $self->_validate_placeholder_hash_with_placeholders;
         # interpolate the cmds in each step and add to new resolved_step_struct
         $self->_interpolate_cmd_in_step_struct_to_resolved_step_struct( $row);
         $self->_step_filter_on_resolved_step_struct if defined $self->step_filter_str; 
         $self->_job_filter_on_resolved_step_struct if defined $self->job_filter_str;
         $self->_once_condition_filter_on_resolved_step_struct;
         $self->placeholder_hash({});
    }    
    #$self->logger->log( "info", "Final Resolved Step Struct: \n" . Dumper $self->pipeline_step_struct_resolved );
}


=method _add_data_source_to_placeholder_hash
   Reads the data source as specified in $self->pipeline_datasource and 
   parses a specified row of the datasource to the placeholder_hash  
=cut
sub _add_data_source_to_placeholder_hash{ 
      #TYPE:  Num :$datasource_row 
      my $self = shift;
      my $datasource_row = shift;
      my $t = $self->pipeline_datasource;
      my @header = $t->header;
      for my $i (0 .. $t->lastCol ) {
         #print $header[$i], " ", $t->col($i), "\n";      
         my @datasource_rows = $t->col($i);
         $self->logger->log( "debug", "Datasource col $i : ".$header[$i] . " =>  $datasource_rows[$datasource_row]");
         #adds in the datasource reference here, so that we can deal specially with datasource stuff later in create_directory_structure
         $self->_placeholder_hash_add_item( "datasource." . $header[$i],  $datasource_rows[$datasource_row]  );

    }   
}


sub _add_software_to_placeholder_hash {
    my $self = shift;
    return unless defined $self->software_dir; 
    my $dir = $self->software_dir;    
    return unless $dir->stat;
    my @software = $dir->children;

    #add to placeholder;   
    for my $i (0 .. $#software) {
       $self->_placeholder_hash_add_item( "software.".$software[$i]->basename, $software[$i]->stringify )
        unless $software[$i]->stringify eq $self->software_ini_file->stringify;       
    }  
    
    # we then need to add the software in in the software.ini file
    return unless defined $self->software_ini;
    return unless $self->software_ini_file->exists;
    foreach my $software_name ( $self->software_ini->{_}->keys  ) {
        $self->_placeholder_hash_add_item(  "software.$software_name", $self->software_ini->{_}->{$software_name} );
    }
    
}


# placeholder hash is where we have {step0}{file1} = value
sub _placeholder_hash_add_item{
   #TYPE: ( Str :$keystr, Str :$value) 
   my $self   = shift;
   my $keystr = shift;
   my $value  = shift; 
   my @keystr = split('\.', $keystr);   
   if( $keystr[0] eq 'jobs'){
	  @keystr = ( $keystr[0], $keystr[1], join('.', @keystr[2 .. $#keystr]  ) ); 
	}else {
      @keystr = ( $keystr[0], join('.', @keystr[1 .. $#keystr]  ) );
	} 
   if (@keystr == 2){
    $self->placeholder_hash->{ $keystr[0] }{ $keystr[1] } = $value ;  
    $self->logger->log("debug", " _placeholder_hash_add_item:  Adding @keystr and $value. Value from hash: " . $self->placeholder_hash->{ $keystr[0] }{ $keystr[1] });
    
   }
    if (@keystr == 3){
       $self->placeholder_hash->{ $keystr[0] }{ $keystr[1] }{ $keystr[2] } = $value;             
   }
} 

# this method could be broken down into
# _add_steps_to_placeholder_hash
# _add_all_job_steps_to_placeholder_hash
# or leave it like this, except call it _add_steps_to_placeholder_hash
# as we are using the same mechanism to generate the file locations.
#
# we are 
sub _add_steps_in_step_struct_to_placeholder_hash {
   #TYPES: ( Num :$job_num ){
   my $self = shift;
   my $job_num = shift;
   my $step_struct = $self->pipeline_step_struct; # we have placeholders parsed for each step
   
   foreach my $step_name (keys %$step_struct ){
      $self->logger->log( "debug", "Processing Pipeline to placeholder hash step " . $step_name);
      my $placeholders = $step_struct->{$step_name}->{placeholders}; 
      next unless defined($placeholders);      
      foreach my $placeholder ( @$placeholders ) {
            
            #           
            # A placeholder that references a step, should be mentioned in that step. 
            # I.e We do not need to worry about it if it appears in other steps.
            # Thus we only process the placeholders in step X that mention this step X.
            # -----
            
            my $output_files;
            my @output_run_dir;
            # case 1. stepX.fileY
            $self->logger->debug("step $step_name. Processing $placeholder"); 
            #my $placeholder_rgx = qr/(step$step_num)(\.(.+))*/; 
            my $placeholder_rgx = qr/^($step_name)(\.(.+))*$/; 
            if( @output_run_dir = $placeholder =~ $placeholder_rgx ){
               $self->logger->debug("step $step_name. Got " . Dumper(@output_run_dir) . " from $placeholder");               
               @output_run_dir = @output_run_dir[0,2];
               if( defined $output_run_dir[1] ){
                   # specific case for steps that are once - they can only refer to a single job directory
                   if ( defined (   $step_struct->{$step_name}->{condition} )){
                      my $min_job = 0;
                      my $jobs = $self->job_filter;
                      ($min_job) = sort {$a <=> $b} @$jobs if defined($jobs);
                      $output_files = $self->_generate_file_output_location($min_job, \@output_run_dir)->stringify;
                   }else{
                      $output_files = $self->_generate_file_output_location($job_num, \@output_run_dir)->stringify;               
                   }
               }elsif ( ( ! defined $output_run_dir[1] ) and ( ! defined $output_run_dir[2] ) and ( defined $output_run_dir[0] ) ) {
                  pop @output_run_dir; #remove last entry
                  $output_files = $self->_generate_file_output_location($job_num, \@output_run_dir)->stringify;
               }
               $self->logger->debug("step $step_name. Extracted a run dir from: @output_run_dir. Full path is $output_files ");  
            }
            
            # case 2.  jobs.stepX.fileY            
            my $jobs_placeholder_rgx = qr/jobs\.([\w\-]+)\.(.+)$/;
            if(@output_run_dir = $placeholder =~ $jobs_placeholder_rgx){
               # get all the files from a step for all jobs
               my @stepfiles;
               my $num_of_jobs = $self->tot_jobs;
               for my $job_num ( 0 .. $num_of_jobs -1 ) {
                   if( $output_run_dir[0] eq 'datasource' ) {                      
                      my $t = $self->pipeline_datasource;
                      my @datasource_rows = $t->col( $output_run_dir[1] );
                      push( @stepfiles,$datasource_rows[$job_num] ); 
                   }else{    
                      push( @stepfiles, 
                            $self->_generate_file_output_location(
                                $job_num, \@output_run_dir)->stringify );                   
                   }
               }
               # JOB FILTER
               my $job_filter = $self->job_filter;
               @stepfiles = @stepfiles[@$job_filter] if defined ( $job_filter );
               $output_files = join ' ', @stepfiles;
               $self->logger->debug("step $step_name. Extracted a run dir from: @output_run_dir. Full path is $output_files ");
            }
            
            # add to placeholder hash - if there is something to add
            if( defined( $output_files ) ){               
                $self->_placeholder_hash_add_item( $placeholder, $output_files); #in order key,value
                $self->logger->debug("step $step_name. Generated file location for placeholder $placeholder as $output_files");
            }
         }  
   }
}

=method _create_directory_structure_from_placeholder_hash  
  At the moment we  allow directory with 'dir' in the name
  to be created as a directory - e.g. for this scenario 
  e.g. 1. some_app --output-dir [ step1.dir ]
  Where some_app requires a pre-existing directory for storing it's output
  We could resolve this issue without using this.
  By doing:
  1. mkdir [% step1.outputdir %]; some_app --output-dir [% step1.outputdir %]
  So it's debatable whether we want automatic creation of directories with 'dir' in the name, 
  but will leave for backwards compatability
  THE DIR BEHAVIOUR SHOULD BE DEPRECATED
=cut

sub _create_directory_structure_from_placeholder_hash {
    my $self = shift;
    $self->logger->debug("Creating directory structure from placeholder hash...");
    # run over hash    
    my $placeholder_hash = $self->placeholder_hash;
    $self->logger->debug(Dumper($placeholder_hash));
    foreach my $step (keys %$placeholder_hash ){
       next if( ($step eq 'step0') or ($step eq 'datasource')); # we don't create any directories from the source step values. (which could be filenames)
       foreach my $param (keys $placeholder_hash->{$step} ){
           if ($param =~ /dir/) {
               my $dir = path( $placeholder_hash->{$step}->{$param} );
               #make_path($dir->stringify);
               $dir->mkpath;
               $self->logger->debug("Making directory: $dir" );
           } else {
              my $file = path( $placeholder_hash->{$step}->{$param} );
              #make_path($file->parent->stringify);
              $file->parent->mkpath;
              $self->logger->debug("Making directory: " . $file->parent->stringify );
           }
       }      
    }
} 

# processing the "X.output file1 file2 .."  lines 
sub _add_expected_output_files_to_placeholder_hash {
     # TYPE: ( Num :$job_num ) 
     my $self = shift;
     my $job_num = shift;
     my $step_struct = $self->pipeline_step_struct; # we have outputfiles parsed for each step     
     foreach my $step_name (keys %$step_struct ){
        $self->logger->debug( "Processing expected output file for Step: " . $step_name); 
        $self->logger->debug("Make filepaths and placeholder hash entry for stated outputs of step $step_name");
        my $file_num = 1;
        $self->logger->debug("So far there are " . ($file_num - 1) . " file(s) registered as outputs for this step");
        my $outputfiles = $step_struct->{$step_name}->{outputfiles};
        if( defined( $outputfiles) ) {
            foreach my $outputfile ( @$outputfiles ) {  
                  #output_path_in_run_dir should be output_path_in_job_dir
                  #check whether the file_path is absolute, if its absolute then we don't generate anything for it  
                 # if($step_name =~ /^[1-9][0-9]*[a-z]*$/){
                 #   my $file_path = $self->_generate_file_output_location( $job_num, ['step'. $step_name , $outputfile] ); 
                 #   $self->placeholder_hash->{"step$step_name"}{"output$file_num"}=$file_path->stringify; 
                 #   $self->logger->debug( "Made step$step_name output$file_num : " . $file_path->stringify);
                 #   $file_num++;
                 # }else{
                    my $file_path = $self->_generate_file_output_location( $job_num, [ $step_name , $outputfile] ); 
                    $self->placeholder_hash->{"$step_name"}{"output$file_num"}=$file_path->stringify; 
                    $self->logger->debug( "Made $step_name output$file_num : " . $file_path->stringify);
                    $file_num++;
                 # }    
            }
        }
     }
}

sub _add_expected_output_files_to_jobs_in_placeholder_hash {
    my $self = shift;
    #get the expected output files
    my $step_struct = $self->pipeline_step_struct;   
    my $placeholder_hash = $self->placeholder_hash;    
    return if( ! exists $placeholder_hash->{jobs} );    
    my $jobs = $placeholder_hash->{jobs};    
    foreach my $step (keys %$jobs){
       next if $step eq 'datasource';
       my $filenames_and_paths = $jobs->{$step};
       my @filenames = keys %$filenames_and_paths;
       foreach my $filename (@filenames){
         my ($output_num) = $filename =~ /output([0-9]+)/;   
         next unless defined( $output_num);      
         my $outputfiles = $step_struct->{$step}->{outputfiles};
         my $name_of_output_file  = $outputfiles->[$output_num-1];
         $filenames_and_paths->{$filename}  =~ s/output$output_num/$name_of_output_file/g;
       }
    }
}


=method _validate_placeholder_with_placeholders
   
   What happens if you add a non existant placeholder e.g. [% step0.fil %] ?
   The parser has parsed out this placeholder - so it is part of the step_struct placeholders for each step
   But, it won't have a corresponding value in the placeholder hash, since it not of the right form.
   Not having a value, might be desired behaviour for somethings (this could be warned), 
   But not existing in the hash is an error.
   
=cut

sub _validate_placeholder_hash_with_placeholders {
   my $self = shift;   
   #foreach step check that we have the right stuff in the placeholder hash
    my $step_struct = $self->pipeline_step_struct;
    my %problem_placeholders;
    foreach my $step_name ( keys %$step_struct) {
       my $placeholders = $step_struct->{$step_name}->{placeholders}; 
       $self->logger->debug( "Validating Step: " . $step_name);
        foreach my $placeholder (@$placeholders) {
           #if($placeholder =~ /^datasource\./){
           #   ($placeholder ) = $placeholder =~ /datasource\.(.+)$/; 
           #}
           #ouch 'App_Pipeline_Lite2_Error', "Check the placeholder $placeholder - it is incorrectly named." 
           #  . Dumper ($self->placeholder_hash)
           #  unless $self->_placeholder_hash_check_item_exists( keystr => $placeholder );
           $problem_placeholders{ $placeholder } = 1  unless $self->_placeholder_hash_check_item_exists(  $placeholder );;  
        }
    }
    my @problem_placeholders = keys %problem_placeholders;
    my $problem_placeholders = join "\n", @problem_placeholders ;
    ouch 'App_Pipeline_Lite4_Error_MISSING_PLACEHOLDER', "Check the placeholders:\n$problem_placeholders\n" 
             if @problem_placeholders > 0;
    
}

sub _interpolate_cmd_in_step_struct_to_resolved_step_struct {
    # ( Num :$job_num ) {
    my $self = shift;   
    my $job_num = shift;   
    my $step_struct = $self->pipeline_step_struct;
    $self->logger->debug("Step struct has : " . Dumper( $step_struct ));
    $self->logger->debug("Placeholder hash has : " . Dumper ( $self->placeholder_hash ) );
    my %output_hash;
    my $interpolated_cmd;
    my $interpolated_output;
    my $new_step_struct = dclone($step_struct);
    my $tt = App::Pipeline::Lite4::Template::TinyMod->new;
    foreach my $step ( keys %$step_struct) {
       my $cmd = $step_struct->{$step}->{cmd}; 
       $interpolated_cmd = $tt->_process($self->placeholder_hash, $cmd);
       $new_step_struct->{$step}->{cmd} =$interpolated_cmd;
       $interpolated_cmd = '';
       
       #also do for output line
      
       if( exists $step_struct->{$step}->{outputfiles} ){ 
           my $output_files = $step_struct->{$step}->{outputfiles}; 
            $new_step_struct->{$step}->{outputfiles} = [];
           foreach my $output (@$output_files){
               $interpolated_output = $tt->_process($self->placeholder_hash, $output);
               my $outputfiles = $new_step_struct->{$step}->{outputfiles}; 
               push(@$outputfiles, $interpolated_output); #CHECK THIS IN TEST
               $interpolated_output = '';
           }
       } 
    }
    $self->pipeline_step_struct_resolved->{$job_num} = $new_step_struct;    
}


sub _placeholder_hash_check_item_exists{
    # TYPE: Str :$keystr
    my $self = shift;
    my $keystr = shift;
    my @keystr = ();
    @keystr = split('\.', $keystr) if ($keystr =~ /\./);
    return exists $self->placeholder_hash->{ $keystr } if( @keystr == 0);
      
    if( $keystr[0] eq 'jobs'){
	  @keystr = ( $keystr[0], $keystr[1], join('.', @keystr[2 .. $#keystr]  ) ); 
	}else {
      @keystr = ( $keystr[0], join('.', @keystr[1 .. $#keystr]  ) );
	} 
	
    return exists $self->placeholder_hash->{ $keystr[0] }{ $keystr[1] } if @keystr == 2;  
    return exists $self->placeholder_hash->{ $keystr[0] }{ $keystr[1] }{ $keystr[2] } if @keystr == 3;   
}

sub _once_condition_filter_on_resolved_step_struct {
   my $self = shift;
   my $resolved_step_struct = $self->pipeline_step_struct_resolved;
   my @keys = sort {$a <=> $b } keys %$resolved_step_struct;
   shift @keys; #remove the lowest job
   $self->logger->debug("Deleting once steps in these steps: @keys");
   foreach my $job_num (@keys){  
       my $job = $resolved_step_struct->{$job_num}; 
       foreach my $step (keys %$job) { 
          next unless ( exists  $job->{$step}->{condition}  ); 
          next unless ( defined $job->{$step}->{condition}  );   
          if ( $job->{$step}->{condition} eq 'once') {
                $self->logger->debug("Deleting once step in $job_num");
                delete $job->{$step};
          }
       }
   }         
} 


sub _generate_file_output_location { 
   # TYPE:( :$job_num, :$output_path_in_run_dir )  
   my ($self, $job_num, $output_path_in_run_dir) = @_;
   if ( defined $self->run_num_dep ) { 
      my $steps = $self->step_filter;
      
      #### WE WANT ANY####
      my $code = sub { my $k = shift; return 1 if( $output_path_in_run_dir->[0] eq $k ); return 0;   };
      my $valid_step = reduce { $a || $code->(local $_ = $b)  } 0,  @$steps;
      # my $valid_step = any{ ($output_path_in_run_dir->[0] =~ $_) } @$steps;
      ###############
            
      if ( !$valid_step ) { 
       my $alt_run_dir = path( $self->output_dir, $self->output_run_name . ($self->run_num_dep) );
       return path( $alt_run_dir , $self->output_job_name .  $job_num, @$output_path_in_run_dir );
      }
   }
   return path( $self->current_run_dir , $self->output_job_name .  $job_num, @$output_path_in_run_dir );
   # return file( $self->output_dir, 'run' . ($self->current_run_num) , $self->output_job_name .  $job_num, @$output_path_in_run_dir );
}

=method _run_number 
   Provides the last run number by looking at previous run directory numbers
=cut
sub _last_run_number {
    my $self=shift;
    #read in files in data directory
    #order by run number
    # - if none then run number is 1.
    my $run_num = max map { if( $_ =~ /run([0-9]+)/){$1}else{} } $self->output_dir->children;
    $run_num = 0 unless (defined $run_num);    
    return $run_num;   
}

1;