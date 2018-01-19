# Workflow for creating a GATK CNV Panel of Normals given a list of normal samples. Supports both WGS and WES.
#
# Notes:
#
# - The interval-list file is required for both WGS and WES workflows and should be a Picard or GATK-style interval list.
#   These intervals will be padded on both sides by the amount specified by PreprocessIntervals.padding (default 250)
#   and split into bins of length specified by PreprocessIntervals.bin_length (default 1000; specify 0 to skip binning,
#   e.g. for WES).  For WGS, the intervals should simply cover the autosomal chromosomes (sex chromosomes may be
#   included, but care should be taken to 1) avoid creating panels of mixed sex, and 2) denoise case samples only
#   with panels containing individuals of the same sex as the case samples).
#
# - Example invocation:
#
#       java -jar cromwell.jar run cnv_somatic_panel_workflow.wdl -i myParameters.json
#
#   See cnv_somatic_panel_workflow_template.json for a template json file to modify with your own parameters (please save
#   your modified version with a different filename and do not commit to the gatk repository).
#
#############

import "cnv_common_tasks.wdl" as CNVTasks

workflow CNVSomaticPanelWorkflow {
    File intervals
    Array[String] normal_bams
    Array[String] normal_bais
    String pon_entity_id
    File ref_fasta_dict
    File ref_fasta_fai
    File ref_fasta
    String gatk_docker
    File? gatk4_jar_override
    Int? mem_for_create_read_count_pon

    # If true, AnnotateIntervals will be run to create GC annotations and explicit GC correction
    # will be performed by the PoN generated by CreateReadCountPanelOfNormals before PCA is performed on subsequent cases
    Boolean? do_explicit_gc_correction

    Array[Pair[String, String]] normal_bams_and_bais = zip(normal_bams, normal_bais)

    call CNVTasks.PreprocessIntervals {
        input:
            intervals = intervals,
            ref_fasta = ref_fasta,
            ref_fasta_fai = ref_fasta_fai,
            ref_fasta_dict = ref_fasta_dict,
            gatk4_jar_override = gatk4_jar_override,
            gatk_docker = gatk_docker
    }

    if (select_first([do_explicit_gc_correction, false])) {
        call CNVTasks.AnnotateIntervals {
            input:
                intervals = PreprocessIntervals.preprocessed_intervals,
                ref_fasta = ref_fasta,
                ref_fasta_fai = ref_fasta_fai,
                ref_fasta_dict = ref_fasta_dict,
                gatk4_jar_override = gatk4_jar_override,
                gatk_docker = gatk_docker
        }
    }

    scatter (normal_bam_and_bai in normal_bams_and_bais) {
        call CNVTasks.CollectCounts {
            input:
                intervals = PreprocessIntervals.preprocessed_intervals,
                bam = normal_bam_and_bai.left,
                bam_idx = normal_bam_and_bai.right,
                gatk4_jar_override = gatk4_jar_override,
                gatk_docker = gatk_docker
        }
    }

    call CreateReadCountPanelOfNormals {
        input:
            pon_entity_id = pon_entity_id,
            read_count_files = CollectCounts.counts,
            annotated_intervals = AnnotateIntervals.annotated_intervals,
            gatk4_jar_override = gatk4_jar_override,
            gatk_docker = gatk_docker,
            mem = mem_for_create_read_count_pon
    }

    output {
        File read_count_pon = CreateReadCountPanelOfNormals.read_count_pon
    }
}

task CreateReadCountPanelOfNormals {
    String pon_entity_id
    Array[File] read_count_files
    Float? minimum_interval_median_percentile
    Float? maximum_zeros_in_sample_percentage
    Float? maximum_zeros_in_interval_percentage
    Float? extreme_sample_median_percentile
    Boolean? do_impute_zeros
    Float? extreme_outlier_truncation_percentile
    Int? number_of_eigensamples
    File? annotated_intervals   #do not perform explicit GC correction by default
    File? gatk4_jar_override

    # Runtime parameters
    Int? mem
    String gatk_docker
    Int? preemptible_attempts
    Int? disk_space_gb

    Int machine_mem = if defined(mem) then select_first([mem]) else 8
    Float command_mem = machine_mem - 0.5

    command <<<
        set -e
        export GATK_LOCAL_JAR=${default="/root/gatk.jar" gatk4_jar_override}

        gatk --java-options "-Xmx${machine_mem}g" CreateReadCountPanelOfNormals \
            --input ${sep=" --input " read_count_files} \
            --minimum-interval-median-percentile ${default="10.0" minimum_interval_median_percentile} \
            --maximum-zeros-in-sample-percentage ${default="5.0" maximum_zeros_in_sample_percentage} \
            --maximum-zeros-in-interval-percentage ${default="5.0" maximum_zeros_in_interval_percentage} \
            --extreme-sample-median-percentile ${default="2.5" extreme_sample_median_percentile} \
            --do-impute-zeros ${default="true" do_impute_zeros} \
            --extreme-outlier-truncation-percentile ${default="0.1" extreme_outlier_truncation_percentile} \
            --number-of-eigensamples ${default="20" number_of_eigensamples} \
            ${"--annotated-intervals " + annotated_intervals} \
            --output ${pon_entity_id}.pon.hdf5
    >>>

    runtime {
        docker: "${gatk_docker}"
        memory: command_mem + " GB"
        disks: "local-disk " + select_first([disk_space_gb, 150]) + " HDD"
        preemptible: select_first([preemptible_attempts, 2])
    }

    output {
        File read_count_pon = "${pon_entity_id}.pon.hdf5"
    }
}
