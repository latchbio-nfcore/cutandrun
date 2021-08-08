/*
========================================================================================
    VALIDATE INPUTS
========================================================================================
*/

// Create summary input parameters map for reporting
def summary_params = NfcoreSchema.paramsSummaryMap(workflow, params)

// Validate input parameters in specialised library
WorkflowCutandrun.initialise(params, log)

// Check input path parameters to see if the files exist if they have been specified
checkPathParamList = [
    params.input,
    params.fasta,
    params.gtf,
    params.blacklist,
    params.bowtie2,
    params.spikein_fasta,
    params.spikein_bowtie2
]
for (param in checkPathParamList) { if (param) { file(param, checkIfExists: true) } }

// Check mandatory parameters that cannot be checked in the groovy lib as we want a channel for them
if (params.input)     { ch_input     = file(params.input)     } else { exit 1, "Input samplesheet not specified!"     }
if (params.blacklist) { ch_blacklist = file(params.blacklist) } else { exit 1, "Genome blacklist file not specified!" }

// Save AWS IGenomes file containing annotation version
def anno_readme = params.genomes[ params.genome ]?.readme
if (anno_readme && file(anno_readme).exists()) {
    file("${params.outdir}/genome/").mkdirs()
    file(anno_readme).copyTo("${params.outdir}/genome/")
}

// Stage dummy file to be used as an optional input where required
ch_dummy_file = file("$projectDir/assets/dummy_file.txt", checkIfExists: true)

// Stage awk files for parsing log files
ch_bt2_to_csv_awk     = file("$projectDir/assets/awk/bt2_report_to_csv.awk"    , checkIfExists: true)
ch_dt_frag_to_csv_awk = file("$projectDir/assets/awk/dt_frag_report_to_csv.awk", checkIfExists: true)

/*
========================================================================================
    CONFIG FILES
========================================================================================
*/

// Load up and check multiqc base config and custom configs
ch_multiqc_config        = file("$projectDir/assets/multiqc_config.yaml", checkIfExists: true)
ch_multiqc_custom_config = params.multiqc_config ? Channel.fromPath(params.multiqc_config) : Channel.empty()

// Header files for MultiQC
ch_frag_len_header_multiqc       = file("$projectDir/assets/multiqc/frag_len_header.txt", checkIfExists: true)

/*
========================================================================================
    RESOLVE FLOW SWITCHING
========================================================================================
*/

def run_genome_prep        = true
def run_input_check        = true
def run_cat_fastq          = true
def run_trim_galore_fastqc = true
def run_alignment          = true
def run_q_filter           = false
def run_mark_dups          = true
def run_remove_dups        = true
def run_peak_calling       = true
def run_reporting          = true
def run_deep_tools         = true
def run_multiqc            = true
def run_peak_plotting      = true

if(params.minimum_alignment_q_score > 0)           { run_q_filter      = true  }
//if(params.skip_markduplicates)                     { run_mark_dups     = false }
if(params.skip_removeduplicates || !run_mark_dups) { run_remove_dups   = false }
//if(params.skip_peak_calling)                       { run_peak_calling  = false }
if(!params.gene_bed || params.skip_heatmaps)       { run_deep_tools    = false }
if(params.skip_multiqc)                            { run_multiqc       = false }
if(params.skip_upset_plots)                        { run_peak_plotting = false }
if(params.skip_reporting) {
    run_reporting     = false
    run_multiqc       = false
    run_peak_plotting = false
}


if(params.only_input) {
    run_genome_prep        = false
    run_cat_fastq          = false
    run_trim_galore_fastqc = false
    run_alignment          = false
    run_q_filter           = false
    run_mark_dups          = false
    run_remove_dups        = false
    run_peak_calling       = false
    run_reporting          = false
    run_multiqc            = false
}

if(params.only_genome) {
    run_input_check        = false
    run_cat_fastq          = false
    run_trim_galore_fastqc = false
    run_alignment          = false
    run_q_filter           = false
    run_mark_dups          = false
    run_remove_dups        = false
    run_peak_calling       = false
    run_reporting          = false
    run_multiqc            = false
}

if(params.only_preqc) {
    run_genome_prep  = false
    run_alignment    = false
    run_q_filter     = false
    run_mark_dups    = false
    run_remove_dups  = false
    run_peak_calling = false
    run_reporting    = false
    run_multiqc      = false
}

if(params.only_alignment) {
    run_q_filter     = false
    run_mark_dups    = false
    run_remove_dups  = false
    run_peak_calling = false
    run_reporting    = false
    run_multiqc      = false
}

if(params.only_filtering) {
    run_peak_calling = false
    run_reporting    = false
    run_multiqc      = false
}

if(params.only_peak_calling) {
    run_reporting = false
    run_multiqc   = false
}

/*
========================================================================================
    INIALISE PARAMETERS AND OPTIONS
========================================================================================
*/

// Don"t overwrite global params.modules, create a copy instead and use that within the main script.
def modules = params.modules.clone()

// Init
def prepare_tool_indices = ["bowtie2"]

// Genome
def genome_options                = params.save_reference ? [publish_dir: "00_genome/target"]        : [publish_files: false]
def spikein_genome_options        = params.save_reference ? [publish_dir: "00_genome/spikein"]       : [publish_files: false]
def bowtie2_index_options         = params.save_reference ? [publish_dir: "00_genome/target/index"]  : [publish_files: false]
def bowtie2_spikein_index_options = params.save_reference ? [publish_dir: "00_genome/spikein/index"] : [publish_files: false]

// Replicate merging
def cat_fastq_options = modules["cat_fastq"]
if (!params.save_merged_fastq) { cat_fastq_options["publish_files"] = false }

// Pre QC
def trimgalore_options = modules["trimgalore"]
if(!params.skip_fastqc) { trimgalore_options.args += " --fastqc" }

// Trimming
trimgalore_options.args  += params.trim_nextseq > 0 ? " --nextseq ${params.trim_nextseq}" : ""
if (params.save_trimmed) { trimgalore_options.publish_files.put("fastq.gz","") }

// Spikein alignment options
def bowtie2_spikein_align_options = modules["bowtie2_spikein_align"]
def samtools_spikein_sort_options = modules["samtools_spikein_sort"]
if (params.save_spikein_aligned) {
    samtools_spikein_sort_options.publish_dir   = "02_alignment/${params.aligner}/spikein"
    samtools_spikein_sort_options.publish_files = ["bai":"","bam":"","stats":"samtools_stats", "flagstat":"samtools_stats", "idxstats":"samtools_stats"]
}

// Main alignment options
def bowtie2_align_options = modules["bowtie2_align"]
def samtools_sort_options = modules["samtools_sort"]
if(params.only_alignment || (!run_q_filter && !run_mark_dups && !run_remove_dups)) {
    samtools_sort_options.publish_dir   = "02_alignment/${params.aligner}/target"
    samtools_sort_options.publish_files = ["bai":"","bam":"","stats":"samtools_stats", "flagstat":"samtools_stats", "idxstats":"samtools_stats"]
}
else if(params.save_align_intermed) {
    samtools_sort_options.publish_dir   = "02_alignment/${params.aligner}/target/intermed/align"
    samtools_sort_options.publish_files = ["bai":"","bam":"","stats":"samtools_stats", "flagstat":"samtools_stats", "idxstats":"samtools_stats"]
}
if(params.save_unaligned) {
    bowtie2_align_options.publish_dir = "02_alignment/${params.aligner}/target"
    bowtie2_align_options.publish_files = ["gz":""]
}

// Q Filter options
samtools_qfilter_options   = modules["samtools_qfilter"]
samtools_view_options      = modules["samtools_view_qfilter"]
samtools_view_options.args = "-b -q " + params.minimum_alignment_q_score
if(!run_mark_dups && !run_remove_dups) {
    samtools_view_options.publish_dir      = "02_alignment/${params.aligner}/target"
    samtools_view_options.publish_files    = ["bam":""]
    samtools_qfilter_options.publish_dir   = "02_alignment/${params.aligner}/target"
    samtools_qfilter_options.publish_files = ["bai":"","stats":"samtools_stats", "flagstat":"samtools_stats", "idxstats":"samtools_stats"]
}
else if(params.save_align_intermed) {
    samtools_view_options.publish_dir      = "02_alignment/${params.aligner}/target/intermed/qfilter"
    samtools_view_options.publish_files    = ["bam":""]
    samtools_qfilter_options.publish_dir   = "02_alignment/${params.aligner}/target/intermed/qfilter"
    samtools_qfilter_options.publish_files = ["bai":"","stats":"samtools_stats", "flagstat":"samtools_stats", "idxstats":"samtools_stats"]
}

// Mark duplicates options
picard_markduplicates_options          = modules["picard_markduplicates"]
picard_markduplicates_samtools_options = modules["picard_markduplicates_samtools"]
if(!run_remove_dups) {
    picard_markduplicates_options.publish_dir            = "02_alignment/${params.aligner}/target/markdup"
    picard_markduplicates_options.publish_files          = ["bam":"","metrics.txt":"picard_metrics"]
    picard_markduplicates_samtools_options.publish_dir   = "02_alignment/${params.aligner}/target/markdup"
    picard_markduplicates_samtools_options.publish_files = ["bai":"","stats":"samtools_stats", "flagstat":"samtools_stats", "idxstats":"samtools_stats"]
}
else if(params.save_align_intermed) {
    picard_markduplicates_options.publish_dir            = "02_alignment/${params.aligner}/target/intermed/markdup"
    picard_markduplicates_options.publish_files          = ["bam":"","metrics.txt":"picard_metrics"]
    picard_markduplicates_samtools_options.publish_dir   = "02_alignment/${params.aligner}/target/intermed/markdup"
    picard_markduplicates_samtools_options.publish_files = ["bai":"","stats":"samtools_stats", "flagstat":"samtools_stats", "idxstats":"samtools_stats"]
}

// Removed duplicates options
def dedup_control_only = true
if(params.dedup_target_reads) { dedup_control_only = false }

picard_deduplicates_options          = modules["picard_dedup"]
picard_deduplicates_samtools_options = modules["picard_dedup_samtools"]
if(run_remove_dups) {
    picard_deduplicates_options.publish_dir            = "02_alignment/${params.aligner}/target/dedup"
    picard_deduplicates_options.publish_files          = ["bam":"","metrics.txt": "picard_metrics"]
    picard_deduplicates_samtools_options.publish_dir   = "02_alignment/${params.aligner}/target/dedup"
    picard_deduplicates_samtools_options.publish_files = ["bai":"","stats":"samtools_stats", "flagstat":"samtools_stats", "idxstats":"samtools_stats"]

    if(dedup_control_only) {
        picard_markduplicates_options.publish_dir            = "02_alignment/${params.aligner}/target/markdup"
        picard_markduplicates_options.publish_files          = ["bam":"","metrics.txt":"picard_metrics"]
        picard_markduplicates_samtools_options.publish_dir   = "02_alignment/${params.aligner}/target/markdup"
        picard_markduplicates_samtools_options.publish_files = ["bai":"","stats":"samtools_stats", "flagstat":"samtools_stats", "idxstats":"samtools_stats"]
    }
}
else if(params.save_align_intermed) {
    picard_deduplicates_options.publish_dir            = "02_alignment/${params.aligner}/target/intermed/dedup"
    picard_deduplicates_options.publish_files          = ["bam":"","metrics.txt":"picard_metrics"]
    picard_deduplicates_samtools_options.publish_dir   = "02_alignment/${params.aligner}/target/intermed/dedup"
    picard_deduplicates_samtools_options.publish_files = ["bai":"","stats":"samtools_stats", "flagstat":"samtools_stats", "idxstats":"samtools_stats"]
}

// Consensus peak options
def awk_threshold           = modules["awk_threshold"]
awk_threshold.command   = "' \$10 >= " + params.replicate_threshold.toString() + " {print \$0}'"
def awk_all_threshold       = modules["awk_threshold"]
awk_threshold.command   = "' \$10 >= 1 {print \$0}'"

// Meta annotation options
def awk_bt2_options         = modules["awk_bt2"]
def awk_bt2_spikein_options = modules["awk_bt2_spikein"]
def awk_dedup_options       = modules["awk_dedup"]

def multiqc_options = modules["multiqc"]
multiqc_options.args += params.multiqc_title ? " --title \"$params.multiqc_title\"" : ""

/*
========================================================================================
    IMPORT LOCAL MODULES/SUBWORKFLOWS
========================================================================================
*/

/*
 * MODULES
 */
include { INPUT_CHECK                    } from "../subworkflows/local/input_check"                          addParams( options: [:]                                        )
include { CAT_FASTQ                      } from "../modules/local/cat_fastq"                                  addParams( options: cat_fastq_options                          )
include { BEDTOOLS_GENOMECOV_SCALE       } from "../modules/local/bedtools_genomecov_scale"                  addParams( options: modules["bedtools_genomecov_bedgraph"]     )
include { SEACR_CALLPEAK as SEACR_NO_IGG } from "../modules/local/seacr_no_igg"                              addParams( options: modules["seacr"]                           )
include { AWK as AWK_NAME_PEAK_BED       } from "../modules/local/awk"                                       addParams( options: modules["awk_name_peak_bed"]               )
include { IGV_SESSION                    } from "../modules/local/igv_session"                               addParams( options: modules["igv"]                             )
include { AWK as AWK_EDIT_PEAK_BED       } from "../modules/local/awk"                                       addParams( options: modules["awk_edit_peak_bed"]               )
include { AWK as AWK_FRAG_BIN            } from "../modules/local/awk"                                       addParams( options: modules["awk_frag_bin"]                    )
include { SAMTOOLS_CUSTOMVIEW            } from "../modules/local/software/samtools/custom_view/main"        addParams( options: modules["samtools_frag_len"]               )
include { EXPORT_META                    } from "../modules/local/export_meta"                               addParams( options: modules["export_meta"]                     )
include { GENERATE_REPORTS               } from "../modules/local/generate_reports"                          addParams( options: modules["generate_reports"]                )
include { GET_SOFTWARE_VERSIONS          } from "../modules/local/get_software_versions"                     addParams( options: [publish_files : ["csv":""]]               )
include { MULTIQC                        } from "../modules/local/multiqc"                                   addParams( options: multiqc_options                            )

/*
 * SUBWORKFLOW: Consisting of a mix of local and nf-core/modules
 */
include { PREPARE_GENOME }                                  from "../subworkflows/local/prepare_genome"           addParams( genome_options: genome_options, spikein_genome_options: spikein_genome_options, bt2_index_options: bowtie2_index_options, bt2_spikein_index_options: bowtie2_spikein_index_options )
include { ALIGN_BOWTIE2 }                                   from "../subworkflows/local/align_bowtie2"            addParams( align_options: bowtie2_align_options, spikein_align_options: bowtie2_spikein_align_options, samtools_spikein_options: samtools_spikein_sort_options, samtools_options: samtools_sort_options )
include { SAMTOOLS_VIEW_SORT_STATS }                        from "../subworkflows/local/samtools_view_sort_stats" addParams( samtools_options: samtools_qfilter_options, samtools_view_options: samtools_view_options )
include { ANNOTATE_META_AWK as ANNOTATE_BT2_META }          from "../subworkflows/local/annotate_meta_awk"        addParams( options: awk_bt2_options, meta_suffix: "_target", script_mode: true )
include { ANNOTATE_META_AWK as ANNOTATE_BT2_SPIKEIN_META }  from "../subworkflows/local/annotate_meta_awk"        addParams( options: awk_bt2_spikein_options, meta_suffix: "_spikein", script_mode: true )
include { CONSENSUS_PEAKS }                                 from "../subworkflows/local/consensus_peaks"          addParams( bedtools_merge_options: modules["bedtools_merge_groups"], sort_options: modules["sort_group_peaks"], awk_threshold_options: awk_threshold, plot_peak_options: modules["plot_peaks"], run_peak_plotting: run_peak_plotting)
include { CONSENSUS_PEAKS as CONSENSUS_PEAKS_ALL}           from "../subworkflows/local/consensus_peaks"          addParams( bedtools_merge_options: modules["bedtools_merge_groups"], sort_options: modules["sort_group_peaks"], awk_threshold_options: awk_all_threshold, plot_peak_options: modules["plot_peaks"], run_peak_plotting: run_peak_plotting)
include { ANNOTATE_META_AWK as ANNOTATE_DEDUP_META }        from "../subworkflows/local/annotate_meta_awk"        addParams( options: awk_dedup_options, meta_suffix: "", meta_prefix: "dedup_", script_mode: false )
include { CALCULATE_FRAGMENTS }                             from "../subworkflows/local/calculate_fragments"      addParams( samtools_options: modules["calc_frag_samtools"], samtools_view_options: modules["calc_frag_samtools_view"], bamtobed_options: modules["calc_frag_bamtobed"], awk_options: modules["calc_frag_awk"], cut_options: modules["calc_frag_cut"] )

/*
========================================================================================
    IMPORT NF-CORE MODULES/SUBWORKFLOWS
========================================================================================
*/

/*
 * MODULES
 */
include { UCSC_BEDCLIP                                             } from "../modules/nf-core/software/ucsc/bedclip/main"            addParams( options: modules["ucsc_bedclip"]          )
include { UCSC_BEDGRAPHTOBIGWIG                                    } from "../modules/nf-core/software/ucsc/bedgraphtobigwig/main"   addParams( options: modules["ucsc_bedgraphtobigwig"] )
include { SEACR_CALLPEAK                                           } from "../modules/nf-core/software/seacr/callpeak/main"          addParams( options: modules["seacr"]                 )
include { DEEPTOOLS_COMPUTEMATRIX as DEEPTOOLS_COMPUTEMATRIX_GENE  } from "../modules/nf-core/software/deeptools/computematrix/main" addParams( options: modules["dt_compute_mat_gene"]   )
include { DEEPTOOLS_COMPUTEMATRIX as DEEPTOOLS_COMPUTEMATRIX_PEAKS } from "../modules/nf-core/software/deeptools/computematrix/main" addParams( options: modules["dt_compute_mat_peaks"]  )
include { DEEPTOOLS_PLOTHEATMAP as DEEPTOOLS_PLOTHEATMAP_GENE      } from "../modules/nf-core/software/deeptools/plotheatmap/main"   addParams( options: modules["dt_plotheatmap_gene"]   )
include { DEEPTOOLS_PLOTHEATMAP as DEEPTOOLS_PLOTHEATMAP_PEAKS     } from "../modules/nf-core/software/deeptools/plotheatmap/main"   addParams( options: modules["dt_plotheatmap_peaks"]  )
include { SAMTOOLS_SORT                                            } from "../modules/nf-core/software/samtools/sort/main.nf"        addParams( options: modules["samtools_sort"]         )
include { SAMTOOLS_INDEX                                           } from "../modules/nf-core/software/samtools/index/main.nf"       addParams( options: modules["samtools_index"]        )

/*
 * SUBWORKFLOW: Consisting entirely of nf-core/modules
 */
include { FASTQC_TRIMGALORE                      } from "../subworkflows/nf-core/fastqc_trimgalore"      addParams( fastqc_options: modules["fastqc"], trimgalore_options: trimgalore_options )
include { MARK_DUPLICATES_PICARD                 } from "../subworkflows/nf-core/mark_duplicates_picard" addParams( markduplicates_options: picard_markduplicates_options, samtools_options: picard_markduplicates_samtools_options, control_only: false )
include { MARK_DUPLICATES_PICARD as DEDUP_PICARD } from "../subworkflows/nf-core/mark_duplicates_picard" addParams( markduplicates_options: picard_deduplicates_options, samtools_options: picard_deduplicates_samtools_options, control_only: dedup_control_only )

/*
========================================================================================
    RUN MAIN WORKFLOW
========================================================================================
*/

workflow CUTANDRUN {

    // Init
    ch_software_versions = Channel.empty()

    /*
     * SUBWORKFLOW: Uncompress and prepare reference genome files
     */
    if(run_genome_prep) {
        PREPARE_GENOME (
            prepare_tool_indices
        )
        ch_software_versions = ch_software_versions.mix(PREPARE_GENOME.out.bowtie2_version.ifEmpty(null))
        ch_software_versions = ch_software_versions.mix(PREPARE_GENOME.out.samtools_version.ifEmpty(null))
    }

    /*
     * SUBWORKFLOW: Read in samplesheet, validate and stage input files
     */
    if(run_input_check) {
        INPUT_CHECK (
            ch_input
        )
        .map {
            meta, fastq ->
                meta.id = meta.id.split("_")[0..-2].join("_")
                [ meta, fastq ] }
        .groupTuple(by: [0])
        .branch {
            meta, fastq ->
                single  : fastq.size() == 1
                    return [ meta, fastq.flatten() ]
                multiple: fastq.size() > 1
                    return [ meta, fastq.flatten() ]
        }
        .set { ch_fastq }
    }

    /*
     * MODULE: Concatenate FastQ files from same sample if required
     */
    if(run_cat_fastq) {
        CAT_FASTQ (
            ch_fastq.multiple
        )
        .mix(ch_fastq.single)
        .set { ch_cat_fastq }
    }
    //EXAMPLE CHANNEL STRUCT: [[id:h3k27me3_R1, group:h3k27me3, replicate:1, single_end:false], [READS]]
    //ch_cat_fastq | view

    /*
     * SUBWORKFLOW: Read QC, trim adapters and perform post-trim read QC
     */
    if(run_trim_galore_fastqc) {
        FASTQC_TRIMGALORE (
            ch_cat_fastq,
            params.skip_fastqc,
            params.skip_trimming
        )
        ch_trimmed_reads     = FASTQC_TRIMGALORE.out.reads
        ch_software_versions = ch_software_versions.mix(FASTQC_TRIMGALORE.out.fastqc_version.first().ifEmpty(null))
        ch_software_versions = ch_software_versions.mix(FASTQC_TRIMGALORE.out.trimgalore_version.first().ifEmpty(null))
    }
    //EXAMPLE CHANNEL STRUCT: [[id:h3k27me3_R1, group:h3k27me3, replicate:1, single_end:false], [READS]]
    //FASTQC_TRIMGALORE.out.reads | view

    /*
    * SUBWORKFLOW: Alignment to target and spikein genome using botwtie2
    */
    ch_orig_bam                   = Channel.empty()
    ch_orig_spikein_bam           = Channel.empty()
    ch_bowtie2_log                = Channel.empty()
    ch_bowtie2_spikein_log        = Channel.empty()
    ch_samtools_bam               = Channel.empty()
    ch_samtools_bai               = Channel.empty()
    ch_samtools_stats             = Channel.empty()
    ch_samtools_flagstat          = Channel.empty()
    ch_samtools_idxstats          = Channel.empty()
    ch_samtools_spikein_bam       = Channel.empty()
    ch_samtools_spikein_bai       = Channel.empty()
    ch_samtools_spikein_stats     = Channel.empty()
    ch_samtools_spikein_flagstat  = Channel.empty()
    ch_samtools_spikein_idxstats  = Channel.empty()
    if(run_alignment) {
        
        if (params.aligner == "bowtie2") {
            ALIGN_BOWTIE2 (
                ch_trimmed_reads,
                PREPARE_GENOME.out.bowtie2_index,
                PREPARE_GENOME.out.bowtie2_spikein_index
            )
            ch_software_versions          = ch_software_versions.mix(ALIGN_BOWTIE2.out.bowtie2_version.first().ifEmpty(null))
            ch_orig_bam                   = ALIGN_BOWTIE2.out.orig_bam
            ch_orig_spikein_bam           = ALIGN_BOWTIE2.out.orig_spikein_bam
            ch_bowtie2_log                = ALIGN_BOWTIE2.out.bowtie2_log
            ch_bowtie2_spikein_log        = ALIGN_BOWTIE2.out.bowtie2_spikein_log

            ch_samtools_bam               = ALIGN_BOWTIE2.out.bam
            ch_samtools_bai               = ALIGN_BOWTIE2.out.bai
            ch_samtools_stats             = ALIGN_BOWTIE2.out.stats
            ch_samtools_flagstat          = ALIGN_BOWTIE2.out.flagstat
            ch_samtools_idxstats          = ALIGN_BOWTIE2.out.idxstats

            ch_samtools_spikein_bam       = ALIGN_BOWTIE2.out.spikein_bam
            ch_samtools_spikein_bai       = ALIGN_BOWTIE2.out.spikein_bai
            ch_samtools_spikein_stats     = ALIGN_BOWTIE2.out.spikein_stats
            ch_samtools_spikein_flagstat  = ALIGN_BOWTIE2.out.spikein_flagstat
            ch_samtools_spikein_idxstats  = ALIGN_BOWTIE2.out.spikein_idxstats
        }
    }
    //EXAMPLE CHANNEL STRUCT: [[id:h3k27me3_R1, group:h3k27me3, replicate:1, single_end:false], [BAM]]
    //ch_samtools_bam | view

    /*
     *  SUBWORKFLOW: Filter reads based on quality metrics
     *  http://biofinysics.blogspot.com/2014/05/how-does-bowtie2-assign-mapq-scores.html
     */
    if (run_q_filter) {
        SAMTOOLS_VIEW_SORT_STATS (
            ch_samtools_bam
        )
        ch_samtools_bam           = SAMTOOLS_VIEW_SORT_STATS.out.bam
        ch_samtools_bai           = SAMTOOLS_VIEW_SORT_STATS.out.bai
        ch_samtools_stats         = SAMTOOLS_VIEW_SORT_STATS.out.stats
        ch_samtools_flagstat      = SAMTOOLS_VIEW_SORT_STATS.out.flagstat
        ch_samtools_idxstats      = SAMTOOLS_VIEW_SORT_STATS.out.idxstats
    }
    //EXAMPLE CHANNEL STRUCT: [[id:h3k27me3_R1, group:h3k27me3, replicate:1, single_end:false], [BAM]]
    //ch_samtools_bam | view

    /*
     * SUBWORKFLOW: Mark duplicates on all samples
     */
    ch_markduplicates_metrics = Channel.empty()
    if (run_mark_dups) {
        MARK_DUPLICATES_PICARD (
            ch_samtools_bam
        )
        ch_samtools_bam           = MARK_DUPLICATES_PICARD.out.bam
        ch_samtools_bai           = MARK_DUPLICATES_PICARD.out.bai
        ch_samtools_stats         = MARK_DUPLICATES_PICARD.out.stats
        ch_samtools_flagstat      = MARK_DUPLICATES_PICARD.out.flagstat
        ch_samtools_idxstats      = MARK_DUPLICATES_PICARD.out.idxstats
        ch_markduplicates_metrics = MARK_DUPLICATES_PICARD.out.metrics
        ch_software_versions      = ch_software_versions.mix(MARK_DUPLICATES_PICARD.out.picard_version.first().ifEmpty(null))
    }
    //EXAMPLE CHANNEL STRUCT: [[id:h3k27me3_R1, group:h3k27me3, replicate:1, single_end:false], [BAM]]
    //ch_samtools_bam | view

    /*
     * SUBWORKFLOW: Remove duplicates - default is on IgG controls only
     */
    ch_dedup_multiqc = Channel.empty()
    if (run_remove_dups) {
        DEDUP_PICARD (
            ch_samtools_bam
        )
        ch_samtools_bam      = DEDUP_PICARD.out.bam
        ch_samtools_bai      = DEDUP_PICARD.out.bai
        ch_samtools_stats    = DEDUP_PICARD.out.stats
        ch_samtools_flagstat = DEDUP_PICARD.out.flagstat
        ch_samtools_idxstats = DEDUP_PICARD.out.idxstats
        ch_dedup_multiqc     = DEDUP_PICARD.out.metrics
    }
    //EXAMPLE CHANNEL STRUCT: [[id:h3k27me3_R1, group:h3k27me3, replicate:1, single_end:false], [BAM]]
    //ch_samtools_bam | view

    /*
     * SUBWORKFLOW: Annotate meta-data with aligner stats for target and spike-in
     * the meta-data is annotated additivley so we only need to track the final channel output
     */
    if (params.aligner == "bowtie2" && run_alignment) {
        ANNOTATE_BT2_META (
            ch_samtools_bam,
            ch_bowtie2_log,
            ch_bt2_to_csv_awk
        )

        ANNOTATE_BT2_SPIKEIN_META (
            ANNOTATE_BT2_META.out.output,
            ch_bowtie2_spikein_log,
            ch_bt2_to_csv_awk
        )
        ch_samtools_bam = ANNOTATE_BT2_SPIKEIN_META.out.output
    }
    // META-DATA example state:
    //[[id:h3k27me3_R1, group:h3k27me3, replicate:1, single_end:false,
    // bt2_total_reads_spikein:9616, bt2_align1_spikein:1, bt2_align_gt1_spikein:0, bt2_non_aligned_spikein:9615, bt2_total_aligned_spikein:1,
    // bt2_total_reads_target:9616, bt2_align1_target:315, bt2_align_gt1_target:449, bt2_non_aligned_target:8852, bt2_total_aligned_target:764], BAM]
    //ch_samtools_bam | view
    //EXPORT_META ( ch_annotated_meta.collect{ it[0] } )

    /*
    * SUBWORKFLOW: Annotate meta-data with duplication stats
    */
    if (run_mark_dups) {
        ANNOTATE_DEDUP_META(
            ch_samtools_bam,
            ch_markduplicates_metrics,
            ch_dummy_file.collect()
        )
        ch_samtools_bam = ANNOTATE_DEDUP_META.out.output
    }
    //EXAMPLE CHANNEL STRUCT: [[META + dedup_library:unknown library, dedup_unpaired_reads_examined:0, dedup_read_pairs_examined:350, dedup_secondary_or_supplementary_rds:0,
    // dedup_unmapped_reads:0, dedup_unpaired_read_duplicates:0, dedup_read_pair_duplicates:0, dedup_read_pair_optical_duplicates:0, dedup_percent_duplication:0,
    // dedup_estimated_library_size:], BAM]
    //ch_samtools_bam | view

    /*
     * CHANNEL: Calculate scale factor for each sample based on a constant devided by the number
     *          of reads aligned to the spike-in genome.
     */
    if (!params.skip_scale) {
        ch_samtools_bam
            .map { row ->
                def denominator = row[0].find{ it.key == "bt2_total_aligned_spikein" }?.value.toInteger()
                [ row[0].id, params.normalisation_c / (denominator != 0 ? denominator : 1) ]
            }
            .set { ch_scale_factor }
    } else {
        ch_samtools_bam
            .map { row ->
                [ row[0].id, 1 ]
            }
            .set { ch_scale_factor }
    }
    // EXAMPLE CHANNEL STRUCT: [id, scale_factor]
    //ch_scale_factor | view

    /*
     * CHANNEL: Create a channel with the scale factor as a seperate value
     */
    ch_samtools_bam
        .map { row -> [row[0].id, row ].flatten()}
        .join ( ch_scale_factor )
        .map { row -> row[1..(row.size() - 1)] }
        .map { row ->
            row[0].put("scale_factor", row[2])
            [ row[0], row[1], row[2] ] }
        .set { ch_samtools_bam_scale }
    //EXAMPLE CHANNEL STRUCT: [[META + scale_factor:10000], BAM, SCALE_FACTOR]
    //ch_samtools_bam_scale | view

    /*
     * CHANNEL: Add the scale factor values to the main meta-data stream
     */
    ch_samtools_bam_scale
        .map { row -> [ row[0], row[1] ] }
        .set { ch_samtools_bam_sf }
    ch_samtools_bam = ch_samtools_bam_sf
    //EXAMPLE CHANNEL STRUCT: [[META], BAM]
    //ch_samtools_bam | view

    if(run_peak_calling) {
        /*
        * MODULE: Convert bam files to bedgraph
        */
        BEDTOOLS_GENOMECOV_SCALE (
            ch_samtools_bam_scale
        )
        //EXAMPLE CHANNEL STRUCT: [META], BEDGRAPH]
        //BEDTOOLS_GENOMECOV_SCALE.out.bedgraph | view

        /*
        * MODULE: Clip off bedgraphs so none overlap beyond chromosome edge
        */
        UCSC_BEDCLIP (
            BEDTOOLS_GENOMECOV_SCALE.out.bedgraph,
            PREPARE_GENOME.out.chrom_sizes
        )
        //EXAMPLE CHANNEL STRUCT: [META], BEDGRAPH]
        //UCSC_BEDCLIP.out.bedgraph | view

        /*
        * MODULE: Convert bedgraph to bigwig
        */
        UCSC_BEDGRAPHTOBIGWIG (
            UCSC_BEDCLIP.out.bedgraph,
            PREPARE_GENOME.out.chrom_sizes
        )
        ch_software_versions = ch_software_versions.mix(UCSC_BEDGRAPHTOBIGWIG.out.version.first().ifEmpty(null))
        //EXAMPLE CHANNEL STRUCT: [[META], BIGWIG]
        //UCSC_BEDGRAPHTOBIGWIG.out.bigwig | view

        /*
         * CHANNEL: Separate bedgraphs into target/control
         */
        BEDTOOLS_GENOMECOV_SCALE.out.bedgraph.branch { it ->
            target: it[0].group != "igg"
            control: it[0].group == "igg"
        }
        .set { ch_bedgraph_split }
        //ch_bedgraph_split.target | view
        //ch_bedgraph_split.control | view

        ch_seacr_bed = Channel.empty()
        if(params.igg_control) {
            /*
            * CHANNEL: Pull control groups
            */
            ch_bedgraph_split.target.map{
                row -> [row[0].control_group, row]
            }
            .set { ch_bg_target_ctrlgrp }
            //ch_bg_target_ctrlgrp | view

            ch_bedgraph_split.control.map{
                row -> [row[0].control_group, row]
            }
            .set { ch_bg_control_ctrlgrp }
            //ch_bg_control_ctrlgrp | view

            /*
            * CHANNEL: Create target/control pairings
            */
            ch_bg_control_ctrlgrp.cross(ch_bg_target_ctrlgrp)
                .map {
                    row -> [row[1][1][0], row[1][1][1], row[0][1][1]]
                }
                .set{ ch_bedgraph_paired }
            // EXAMPLE CHANNEL STRUCT: [[META], TARGET_BEDGRAPH, CONTROL_BEDGRAPH]
            //ch_bedgraph_paired | view

            /*
             * MODULE: Call peaks with IgG control
             */
            SEACR_CALLPEAK (
                ch_bedgraph_paired
            )
            ch_seacr_bed = SEACR_CALLPEAK.out.bed
            ch_software_versions = ch_software_versions.mix(SEACR_CALLPEAK.out.version.first().ifEmpty(null))
            // EXAMPLE CHANNEL STRUCT: [[META], BED]
            //SEACR_CALLPEAK.out.bed | view
        }
        else {
            /*
             * CHANNEL: Load peak threshold into channel
             */
            ch_peak_threshold = Channel.value(params.peak_threshold)

            /*
            * MODULE: Call peaks without IgG Control
            */
            SEACR_NO_IGG (
                ch_bedgraph_split.target,
                ch_peak_threshold
            )
            ch_seacr_bed = SEACR_NO_IGG.out.bed
            ch_software_versions = ch_software_versions.mix(SEACR_NO_IGG.out.version.first().ifEmpty(null))
            // EXAMPLE CHANNEL STRUCT: [[META], BED]
            //SEACR_NO_IGG.out.bed | view
        }

        /*
        * MODULE: Add sample identifier column to peak beds
        */
        AWK_NAME_PEAK_BED ( 
            ch_seacr_bed 
        )
        // EXAMPLE CHANNEL STRUCT: [[META], BED]
        //AWK_NAME_PEAK_BED.out.file | view

        /*
        * CHANNEL: Group all samples
        */
        AWK_NAME_PEAK_BED.out.file
            .map { row -> [ 1, row[1] ] }
            .groupTuple(by: [0])
            .map { row ->
                new_meta = [:]
                new_meta.put( "id", "all_samples" )
                [ new_meta, row[1].flatten() ]
            }
            .set { ch_seacr_bed_all }
        // EXAMPLE CHANNEL STRUCT: [[id: all_samples], BED1, BED2, BEDn...]
        //ch_seacr_bed_all | view

        /*
        * SUBWORKFLOW: Construct group consensus peaks
        */
        CONSENSUS_PEAKS_ALL ( 
            ch_seacr_bed_all 
        )
        // EXAMPLE CHANNEL STRUCT: [[META], BED]
        //CONSENSUS_PEAKS_ALL.out.bed | view

        /*
        * CHANNEL: Group samples based on group
        */
        AWK_NAME_PEAK_BED.out.file
            .map { row -> [ row[0].group, row[1] ] }
            .groupTuple(by: [0])
            .map { row ->
                new_meta = [:]
                new_meta.put( "id", row[0] )
                [ new_meta, row[1].flatten() ]
            }
            .set { ch_seacr_bed_group }
        // EXAMPLE CHANNEL STRUCT: [[id: <GROUP>], BED1, BED2, BEDn...]
        //ch_seacr_bed_group | view

        /*
        * SUBWORKFLOW: Construct group consensus peaks
        * where there is more than 1 replicate in a group
        */
        CONSENSUS_PEAKS ( 
            ch_seacr_bed_group 
        )
        // EXAMPLE CHANNEL STRUCT: [[META], BED]
        //CONSENSUS_PEAKS.out.bed | view

         /*
         * SUBWORKFLOW: Calculate fragment bed from bams
         * - Filter for mapped reads
         * - Convert to bed file
         * - Keep the read pairs that are on the same chromosome and fragment length less than 1000bp
         * - Only extract the fragment related columns using cut
         */
        CALCULATE_FRAGMENTS (
            ch_samtools_bam
        )
        ch_software_versions = ch_software_versions.mix(CALCULATE_FRAGMENTS.out.bedtools_version.first().ifEmpty(null))
        //EXAMPLE CHANNEL STRUCT: NO CHANGE
        //CALCULATE_FRAGMENTS.out.bed | view

        /*
        * MODULE: Bin the fragments into 500bp bins ready for downstream reporting
        */
        AWK_FRAG_BIN(
            CALCULATE_FRAGMENTS.out.bed
        )
        //AWK_FRAG_BIN.out.file | view

        /*
        * MODULE: Calculate fragment lengths
        */
        SAMTOOLS_CUSTOMVIEW (
            ch_samtools_bam,
            ch_samtools_bai
        )
        //SAMTOOLS_CUSTOMVIEW.out.tsv | view
    }

    if(run_reporting) {
        /*
         * CHANNEL: Remove IgG from bigwig channel
         */
        UCSC_BEDGRAPHTOBIGWIG.out.bigwig
            .filter { it[0].group != "igg" }
            .set { ch_bigwig_no_igg }
        //ch_bigwig_no_igg | view

        if(!params.skip_igv) {
            /*
            * MODULE: Create igv session
            */
            IGV_SESSION (
                PREPARE_GENOME.out.fasta,
                PREPARE_GENOME.out.gtf,
                ch_seacr_bed.collect{it[1]}.ifEmpty([]),
                UCSC_BEDGRAPHTOBIGWIG.out.bigwig.collect{it[1]}.ifEmpty([])
            )
        }

        /*
        * MODULE: Extract max signal from peak beds
        */
        AWK_EDIT_PEAK_BED (
            ch_seacr_bed
        )
        //AWK_EDIT_PEAK_BED.out.file | view

        /*
        * CHANNEL: Structure output for join on id
        */
        AWK_EDIT_PEAK_BED.out.file
            .map { row -> [row[0].id, row ].flatten()}
            .set { ch_seacr_bed_id }
        //ch_seacr_bed_id | view

        /*
            * CHANNEL: Join beds and bigwigs on id
            */
        ch_bigwig_no_igg
            .map { row -> [row[0].id, row ].flatten()}
            .join ( ch_seacr_bed_id )
            .set { ch_dt_peaks }
        //ch_dt_peaks | view

        ch_dt_peaks
            .map { row -> row[1,2] }
            .set { ch_ordered_bigwig }
        //ch_ordered_bigwig | view

        ch_dt_peaks
            .map { row -> row[-1] }
            .set { ch_ordered_seacr_max }
        //ch_ordered_seacr_max | view

        if (run_deep_tools){
            /*
            * MODULE: Compute DeepTools matrix used in heatmap plotting for Genes
            */
            DEEPTOOLS_COMPUTEMATRIX_GENE (
                ch_bigwig_no_igg,
                PREPARE_GENOME.out.bed
            )
            ch_software_versions = ch_software_versions.mix(DEEPTOOLS_COMPUTEMATRIX_GENE.out.version.first().ifEmpty(null))

            /*
            * MODULE: Calculate DeepTools heatmap
            */
            DEEPTOOLS_PLOTHEATMAP_GENE (
                DEEPTOOLS_COMPUTEMATRIX_GENE.out.matrix
            )

            /*
            * MODULE: Compute DeepTools matrix used in heatmap plotting for Peaks
            */
            DEEPTOOLS_COMPUTEMATRIX_PEAKS (
                ch_ordered_bigwig,
                ch_ordered_seacr_max
            )
            //EXAMPLE CHANNEL STRUCT: [[META], MATRIX]
            //DEEPTOOLS_COMPUTEMATRIX_PEAKS.out.matrix | view

            /*
            * MODULE: Calculate DeepTools heatmap
            */
            DEEPTOOLS_PLOTHEATMAP_PEAKS (
                DEEPTOOLS_COMPUTEMATRIX_PEAKS.out.matrix
            )
        }

        /*
        * MODULE: Export meta-data to csv file
        */
        EXPORT_META (
            ch_samtools_bam.collect{it[0]}.ifEmpty(["{NO-DATA}"])
        )

        /*
        * MODULE: Sort bams by mate pair ids (no position)
        */
        SAMTOOLS_SORT (
            ch_samtools_bam
        )
        //EXAMPLE CHANNEL STRUCT: [[META], BAM]
        //SAMTOOLS_SORT.out.bam | view

        SAMTOOLS_INDEX (
            SAMTOOLS_SORT.out.bam
        )
        //EXAMPLE CHANNEL STRUCT: [[META], BAI]
        //SAMTOOLS_INDEX.out.bai | view

        /*
        * MODULE: Generate python reporting using mixture of meta-data and direct file processing
        */
        ch_frag_len_multiqc = Channel.empty()
        GENERATE_REPORTS(
            EXPORT_META.out.csv,                        // meta-data report stats
            SAMTOOLS_CUSTOMVIEW.out.tsv.collect{it[1]}, // raw fragments
            AWK_FRAG_BIN.out.file.collect{it[1]},       // binned fragments
            ch_seacr_bed.collect{it[1]},                // peak beds
            SAMTOOLS_SORT.out.bam.collect{it[1]},       // bam files sorted by mate pair ids
            SAMTOOLS_INDEX.out.bai.collect{it[1]},      // bai files sorted by mate pair ids
            ch_frag_len_header_multiqc                  // multiqc config header for fragment length distribution plot
        )
        ch_frag_len_multiqc  = GENERATE_REPORTS.out.frag_len_multiqc
        ch_software_versions = ch_software_versions.mix(GENERATE_REPORTS.out.version.ifEmpty(null))

        /*
        * MODULE: Collect software versions used in pipeline
        */
        ch_software_versions
            .map { it -> if (it) [ it.baseName, it ] }
            .groupTuple()
            .map { it[1][0] }
            .flatten()
            .collect()
            .set { ch_software_versions }

        GET_SOFTWARE_VERSIONS (
            ch_software_versions.map { it }.collect()
        )
    }

    /*
     * MODULE: Multiqc
     */
    if (run_multiqc) {
        workflow_summary    = WorkflowCutandrun.paramsSummaryMultiqc(workflow, summary_params)
        ch_workflow_summary = Channel.value(workflow_summary)

        MULTIQC (
            ch_multiqc_config,
            ch_multiqc_custom_config.collect().ifEmpty([]),
            GET_SOFTWARE_VERSIONS.out.yaml.collect(),
            ch_workflow_summary.collectFile(name: "workflow_summary_mqc.yaml"),
            FASTQC_TRIMGALORE.out.fastqc_zip.collect{it[1]}.ifEmpty([]),
            FASTQC_TRIMGALORE.out.trim_zip.collect{it[1]}.ifEmpty([]),
            FASTQC_TRIMGALORE.out.trim_log.collect{it[1]}.ifEmpty([]),
            ch_bowtie2_log.collect{it[1]}.ifEmpty([]),
            ch_bowtie2_spikein_log.collect{it[1]}.ifEmpty([]),
            ch_samtools_stats.collect{it[1]}.ifEmpty([]),
            ch_samtools_flagstat.collect{it[1]}.ifEmpty([]),
            ch_samtools_idxstats.collect{it[1]}.ifEmpty([]),
            ch_markduplicates_metrics.collect{it[1]}.ifEmpty([]),
            ch_frag_len_multiqc.collect().ifEmpty([])
        )
        multiqc_report = MULTIQC.out.report.toList()
    }
}

////////////////////////////////////////////////////
/* --              COMPLETION EMAIL            -- */
////////////////////////////////////////////////////

workflow.onComplete {
    NfcoreTemplate.email(workflow, params, summary_params, projectDir, log, multiqc_report)
    NfcoreTemplate.summary(workflow, params, log)
}

////////////////////////////////////////////////////
/* --                  THE END                 -- */
////////////////////////////////////////////////////