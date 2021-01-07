version 1.0

task md5sum {
  input {
    File in_file
  }
  command {
    md5sum ${in_file} | cut -f 1 | tee MD5
  }
  output {
    String md5 = read_string("MD5")
  }
  runtime {
    docker: "ubuntu"
    memory: "1 GB"
    cpu: 1
    disks: "local-disk 100 HDD"
    dx_instance_type: "mem1_ssd2_v2_x2"
  }
}

task download_fasta {
  input {
    String         out_prefix
    Array[String]+ accessions
    String         emailAddress

    String         docker="quay.io/broadinstitute/viral-phylo:2.1.13.1"
  }

  command {
    ncbi.py --version | tee VERSION
    ncbi.py fetch_fastas \
        ${emailAddress} \
        . \
        ${sep=' ' accessions} \
        --combinedFilePrefix ${out_prefix} \
  }

  output {
    File   sequences_fasta  = "${out_prefix}.fasta"
    String viralngs_version = read_string("VERSION")
  }

  runtime {
    docker: "${docker}"
    memory: "7 GB"
    cpu: 2
    dx_instance_type: "mem2_ssd1_v2_x2"
  }
}

task download_annotations {
  input {
    Array[String]+ accessions
    String         emailAddress
    String         combined_out_prefix

    String         docker="quay.io/broadinstitute/viral-phylo:2.1.13.1"
  }

  command {
    set -ex -o pipefail
    ncbi.py --version | tee VERSION
    ncbi.py fetch_feature_tables \
        ${emailAddress} \
        ./ \
        ${sep=' ' accessions} \
        --loglevel DEBUG
    ncbi.py fetch_fastas \
        ${emailAddress} \
        ./ \
        ${sep=' ' accessions} \
        --combinedFilePrefix "${combined_out_prefix}" \
        --loglevel DEBUG
  }

  output {
    File        combined_fasta   = "${combined_out_prefix}.fasta"
    Array[File] genomes_fasta    = glob("*.fasta")
    Array[File] features_tbl     = glob("*.tbl")
    String      viralngs_version = read_string("VERSION")
  }

  runtime {
    docker: "${docker}"
    memory: "7 GB"
    cpu: 2
    dx_instance_type: "mem2_ssd1_v2_x2"
  }
}

task annot_transfer {
  meta {
    description: "Given a reference genome annotation in TBL format (e.g. from Genbank or RefSeq) and a multiple alignment of that reference to other genomes, produce new annotation files (TBL format with appropriate coordinate conversions) for each sequence in the multiple alignment. Resulting output can be fed to tbl2asn for Genbank submission."
  }

  input {
    File         multi_aln_fasta
    File         reference_fasta
    Array[File]+ reference_feature_table

    String  docker="quay.io/broadinstitute/viral-phylo:2.1.13.1"
  }

  parameter_meta {
    multi_aln_fasta: {
      description: "multiple alignment of sample sequences against a reference genome -- for a single chromosome",
      patterns: ["*.fasta"]
    }
    reference_fasta: {
      description: "Reference genome, all segments/chromosomes in one fasta file. Headers must be Genbank accessions.",
      patterns: ["*.fasta"]
    }
    reference_feature_table: {
      description: "NCBI Genbank feature tables, one file for each segment/chromosome described in reference_fasta.",
      patterns: ["*.tbl"]
    }
  }

  command {
    set -e
    ncbi.py --version | tee VERSION
    ncbi.py tbl_transfer_prealigned \
        ${multi_aln_fasta} \
        ${reference_fasta} \
        ${sep=' ' reference_feature_table} \
        . \
        --oob_clip \
        --loglevel DEBUG
  }

  output {
    Array[File] transferred_feature_tables = glob("*.tbl")
    String      viralngs_version           = read_string("VERSION")
  }

  runtime {
    docker: "${docker}"
    memory: "3 GB"
    cpu: 2
    dx_instance_type: "mem1_ssd1_v2_x2"
  }
}

task align_and_annot_transfer_single {
  meta {
    description: "Given a reference genome annotation in TBL format (e.g. from Genbank or RefSeq) and new genome not in Genbank, produce new annotation files (TBL format with appropriate coordinate conversions) for the new genome. Resulting output can be fed to tbl2asn for Genbank submission."
  }

  input {
    File         genome_fasta
    Array[File]+ reference_fastas
    Array[File]+ reference_feature_tables

    String  docker="quay.io/broadinstitute/viral-phylo:2.1.13.1"
  }

  parameter_meta {
    genome_fasta: {
      description: "New genome, all segments/chromosomes in one fasta file. Must contain the same number of sequences as reference_fasta",
      patterns: ["*.fasta"]
    }
    reference_fastas: {
      description: "Reference genome, each segment/chromosome in a separate fasta file, in the exact same count and order as the segments/chromosomes described in genome_fasta. Headers must be Genbank accessions.",
      patterns: ["*.fasta"]
    }
    reference_feature_tables: {
      description: "NCBI Genbank feature table, each segment/chromosome in a separate TBL file, in the exact same count and order as the segments/chromosomes described in genome_fasta and reference_fastas. Accession numbers in the TBL files must correspond exactly to those in reference_fasta.",
      patterns: ["*.tbl"]
    }
  }

  command {
    set -e
    ncbi.py --version | tee VERSION
    mkdir -p out
    ncbi.py tbl_transfer_multichr \
        "${genome_fasta}" \
        out \
        --ref_fastas ${sep=' ' reference_fastas} \
        --ref_tbls ${sep=' ' reference_feature_tables} \
        --oob_clip \
        --loglevel DEBUG
  }

  output {
    Array[File]+ genome_per_chr_tbls   = glob("out/*.tbl")
    Array[File]+ genome_per_chr_fastas = glob("out/*.fasta")
    String       viralngs_version      = read_string("VERSION")
  }

  runtime {
    docker: "${docker}"
    memory: "15 GB"
    cpu: 4
    dx_instance_type: "mem2_ssd1_v2_x4"
    preemptible: 1
  }
}

task structured_comments {
  input {
    File    assembly_stats_tsv

    File?   filter_to_ids

    String  docker="quay.io/broadinstitute/viral-core:2.1.13"
  }
  String out_base = basename(assembly_stats_tsv, '.txt')
  command <<<
    set -e

    python3 << CODE
      import util.file

      samples_to_filter_to = set()
      if "~{default='' filter_to_ids}":
          with open("~{default='' filter_to_ids}", 'rt') as inf:
              samples_to_filter_to = set(line.strip() for line in inf)

      out_headers_total = ('SeqID', 'StructuredCommentPrefix', 'Assembly Method', 'Coverage', 'Sequencing Technology', 'StructuredCommentSuffix')
      with open("~{out_base}.cmt", 'wt') as outf:
          outf.write('\t'.join(out_headers_total)+'\n')

          for row in util.file.read_tabfile_dict(in_table):
              outrow = dict((h, row.get(header_key_map.get(h,h), '')) for h in out_headers)

              if samples_to_filter_to:
                if row['SeqID'] not in samples_to_filter_to:
                    continue

              if outrow['Coverage']:
                outrow['Coverage'] = "{}x".format(round(float(outrow['Coverage'])))
              outrow['StructuredCommentPrefix'] = 'Assembly-Data'
              outrow['StructuredCommentSuffix'] = 'Assembly-Data'
              outf.write('\t'.join(outrow[h] for h in out_headers)+'\n')
    CODE
  >>>
  output {
    File   structured_comment_table = "~{out_base}.cmt"
  }
  runtime {
    docker: "~{docker}"
    memory: "1 GB"
    cpu: 1
    dx_instance_type: "mem1_ssd1_v2_x2"
  }
}

task rename_fasta {
  input {
    File    genome_fasta
    String  new_name

    String  docker="quay.io/broadinstitute/viral-core:2.1.13"
  }
  command {
    set -e
    file_utils.py rename_fasta_sequences \
      "~{genome_fasta}.fasta" "~{new_name}.fasta" "~{new_name}"
  }
  output {
    File renamed_fasta = "~{new_name}.fasta"
  }
  runtime {
    docker: "~{docker}"
    memory: "1 GB"
    cpu: 1
    dx_instance_type: "mem1_ssd1_v2_x2"
  }
}

task lookup_table_by_filename {
  input {
    String  id
    File    mapping_tsv
    Int     return_col=2

    String  docker="ubuntu"
  }
  command {
    set -e -o pipefail
    grep ^"~{id}" ~{mapping_tsv} | cut -f ~{return_col} > OUTVAL
  }
  output {
    String value = read_string("OUTVAL")
  }
  runtime {
    docker: "~{docker}"
    memory: "1 GB"
    cpu: 1
    dx_instance_type: "mem1_ssd1_v2_x2"
  }
}

task biosample_to_genbank {
  meta {
    description: "Prepares two input metadata files for Genbank submission based on a BioSample registration attributes table (attributes.tsv) since all of the necessary values are there. This produces both a Genbank Source Modifier Table and a BioSample ID map file that can be fed into the prepare_genbank task."
  }
  input {
    File  biosample_attributes
    Int   num_segments=1
    Int   taxid

    File? filter_to_ids

    String  docker="quay.io/broadinstitute/viral-phylo:2.1.13.1"
  }
  String base = basename(biosample_attributes, ".txt")
  command {
    set -ex -o pipefail
    ncbi.py --version | tee VERSION
    ncbi.py biosample_to_genbank \
        "${biosample_attributes}" \
        ${num_segments} \
        ${taxid} \
        "${base}".genbank.src \
        "${base}".biosample.map.txt \
        ${'--filter_to_samples ' + filter_to_ids} \
        --biosample_in_smt \
        --loglevel DEBUG
  }
  output {
    File genbank_source_modifier_table = "${base}.genbank.src"
    File biosample_map                 = "${base}.biosample.map.txt"
  }
  runtime {
    docker: "${docker}"
    memory: "1 GB"
    cpu: 1
    dx_instance_type: "mem1_ssd1_v2_x2"
  }
}

task prepare_genbank {
  meta {
    description: "this task runs NCBI's tbl2asn"
  }

  input {
    Array[File]+ assemblies_fasta
    Array[File]  annotations_tbl
    File         authors_sbt
    File?        biosampleMap
    File?        genbankSourceTable
    File?        coverage_table
    String?      sequencingTech
    String?      comment
    String?      organism
    String?      molType
    String?      assembly_method
    String?      assembly_method_version

    Int?         machine_mem_gb
    String       docker="quay.io/broadinstitute/viral-phylo:2.1.13.1"
  }

  parameter_meta {
    assemblies_fasta: {
      description: "Assembled genomes. One chromosome/segment per fasta file.",
      patterns: ["*.fasta"]
    }
    annotations_tbl: {
      description: "Gene annotations in TBL format, one per fasta file. Filename basenames must match the assemblies_fasta basenames. These files are typically output from the ncbi.annot_transfer task.",
      patterns: ["*.tbl"]
    }
    authors_sbt: {
      description: "A genbank submission template file (SBT) with the author list, created at https://submit.ncbi.nlm.nih.gov/genbank/template/submission/",
      patterns: ["*.sbt"]
    }
    biosampleMap: {
      description: "A two column tab text file mapping sample IDs (first column) to NCBI BioSample accession numbers (second column). These typically take the format 'SAMN****' and are obtained by registering your samples first at https://submit.ncbi.nlm.nih.gov/",
      patterns: ["*.txt", "*.tsv"]
    }
    genbankSourceTable: {
      description: "A tab-delimited text file containing requisite metadata for Genbank (a 'source modifier table'). https://www.ncbi.nlm.nih.gov/WebSub/html/help/genbank-source-table.html",
      patterns: ["*.txt", "*.tsv"]
    }
    coverage_table: {
      description: "A two column tab text file mapping sample IDs (first column) to average sequencing coverage (second column, floating point number).",
      patterns: ["*.txt", "*.tsv"]
    }
    sequencingTech: {
      description: "The type of sequencer used to generate reads. NCBI has a controlled vocabulary for this value which can be found here: https://submit.ncbi.nlm.nih.gov/structcomment/nongenomes/"
    }
    organism: {
      description: "The scientific name for the organism being submitted. This is typically the species name and should match the name given by the NCBI Taxonomy database. For more info, see: https://www.ncbi.nlm.nih.gov/Sequin/sequin.hlp.html#Organism"
    }
    molType: {
      description: "The type of molecule being described. Any value allowed by the INSDC controlled vocabulary may be used here. Valid values are described at http://www.insdc.org/controlled-vocabulary-moltype-qualifier"
    }
    assembly_method: {
      description: "Very short description of the software approach used to assemble the genome. We typically provide a github link here. If this is specified, assembly_method_version should also be specified."
    }
    assembly_method_version: {
      description: "The version of the software used. If this is specified, assembly_method should also be specified."
    }
    comment: {
      description: "Optional comments that can be displayed in the COMMENT section of the Genbank record. This may include any disclaimers about assembly quality or notes about pre-publication availability or requests to discuss pre-publication use with authors."
    }

  }

  command {
    set -ex -o pipefail
    ncbi.py --version | tee VERSION
    cp ${sep=' ' annotations_tbl} .

    touch special_args
    if [ -n "${comment}" ]; then
      echo "--comment" >> special_args
      echo "${comment}" >> special_args
    fi
    if [ -n "${sequencingTech}" ]; then
      echo "--sequencing_tech" >> special_args
      echo "${sequencingTech}" >> special_args
    fi
    if [ -n "${organism}" ]; then
      echo "--organism" >> special_args
      echo "${organism}" >> special_args
    fi
    if [ -n "${molType}" ]; then
      echo "--mol_type" >> special_args
      echo "${molType}" >> special_args
    fi
    if [ -n "${assembly_method}" -a -n "${assembly_method_version}" ]; then
      echo "--assembly_method" >> special_args
      echo "${assembly_method}" >> special_args
      echo "--assembly_method_version" >> special_args
      echo "${assembly_method_version}" >> special_args
    fi
    if [ -n "${coverage_table}" ]; then
      echo -e "sample\taln2self_cov_median" > coverage_table.txt
      cat ${coverage_table} >> coverage_table.txt
      echo "--coverage_table" >> special_args
      echo coverage_table.txt >> special_args
    fi

    cat special_args | xargs -d '\n' ncbi.py prep_genbank_files \
        ${authors_sbt} \
        ${sep=' ' assemblies_fasta} \
        . \
        ${'--biosample_map ' + biosampleMap} \
        ${'--master_source_table ' + genbankSourceTable} \
        --loglevel DEBUG
    zip sequins_only.zip *.sqn
    zip all_files.zip *.sqn *.cmt *.gbf *.src *.fsa *.val
    mv errorsummary.val errorsummary.val.txt # to keep it separate from the glob
  }

  output {
    File        submission_zip           = "sequins_only.zip"
    File        archive_zip              = "all_files.zip"
    Array[File] sequin_files             = glob("*.sqn")
    Array[File] structured_comment_files = glob("*.cmt")
    Array[File] genbank_preview_files    = glob("*.gbf")
    Array[File] source_table_files       = glob("*.src")
    Array[File] fasta_per_chr_files      = glob("*.fsa")
    Array[File] validation_files         = glob("*.val")
    File        errorSummary             = "errorsummary.val.txt"
    String      viralngs_version         = read_string("VERSION")
  }

  runtime {
    docker: "${docker}"
    memory: select_first([machine_mem_gb, 3]) + " GB"
    cpu: 2
    dx_instance_type: "mem1_ssd1_v2_x2"
  }
}

task package_genbank_ftp_submission {
  meta {
    description: "Prepares a zip and xml file for FTP-based NCBI Genbank submission according to instructions at https://www.ncbi.nlm.nih.gov/viewvc/v1/trunk/submit/public-docs/genbank/SARS-CoV-2/."
  }
  input {
    File   sequences_fasta
    File   structured_comment_table
    File   source_modifier_table
    File   author_template_sbt
    String submission_name
    String submission_uid
    String spuid_namespace
    String account_name

    String  docker="quay.io/broadinstitute/viral-baseimage:0.1.19"
  }
  command <<<
    set -e

    # make the submission zip file
    cp "~{sequences_fasta}" sequence.fsa
    cp "~{structured_comment_table}" comment.cmt
    cp "~{source_modifier_table}" source.src
    cp "~{author_template_sbt}" template.sbt
    zip "~{submission_uid}.zip" sequences.fsa comment.cmt source.src template.sbt

    # make the submission xml file
    SUB_NAME="~{submission_name}"
    ACCT_NAME="~{account_name}"
    SPUID="~{submission_uid}"
    cat << EOF > submission.xml
    <?xml version="1.0"?>
    <Submission>
      <Description>
        <Comment>$SUB_NAME</Comment>
        <Organization type="center" role="owner">
          <Name>$ACCT_NAME</Name>
        </Organization>
      </Description>
      <Action>
        <AddFiles target_db="GenBank">
          <File file_path="$SPUID.zip">
            <DataType>genbank-submission-package</DataType>
          </File>
          <Attribute name="wizard">BankIt_SARSCoV2_api</Attribute>
          <Identifier>
            <SPUID spuid_namespace="~{spuid_namespace}">$SPUID</SPUID>
          </Identifier>
        </AddFiles>
      </Action>
    </Submission>
    EOF

    # make the (empty) ready file
    touch submit.ready
  >>>
  output {
    File submission_zip = "~{submission_uid}.zip"
    File submission_xml = "submission.xml"
    File submit_ready = "submit.ready"
  }
  runtime {
    docker: "~{docker}"
    memory: "1 GB"
    cpu: 1
    dx_instance_type: "mem1_ssd1_v2_x2"
  }
}

task vadr {
  meta {
    description: "Runs NCBI's Viral Annotation DefineR for annotation and QC."
  }
  input {
    File   genome_fasta
    String vadr_opts="-r -s --nomisc --lowsimterm 2 --mkey NC_045512 --fstlowthr 0.0 --alt_fail lowscore,fsthicnf,fstlocnf"

    String  docker="staphb/vadr:1.1"
  }
  String out_base = basename(genome_fasta, '.fasta')
  command <<<
    set -e

    # find available RAM
    RAM_MB=$(free -m | head -2 | tail -1 | awk '{print $2}')

    # run VADR
    v-annotate.pl \
      ~{vadr_opts} \
      --mxsize $RAM_MB \
      "~{genome_fasta}" \
      ~{out_base}

    # package everything for output
    tar -C ~{out_base} -czvf ~{out_base}.vadr.tar.gz .

    # prep alerts into a tsv file for parsing
    cat ~{out_base}/~{out_base}.vadr.alt.list| tail -n +2 | cut -f 2- > ~{out_base}.vadr.alerts.tsv
  >>>
  output {
    File feature_tbl  = "~{out_base}/~{out_base}.vadr.pass.tbl"
    Int  num_alerts = length(read_lines("~{out_base}.vadr.alerts.tsv"))
    File alerts_list = "~{out_base}/~{out_base}.vadr.alt.list"
    Array[Array[String]] alerts = read_tsv("~{out_base}.vadr.alerts.tsv")
    File outputs_tgz = "~{out_base}.vadr.tar.gz"
  }
  runtime {
    docker: "~{docker}"
    memory: "64 GB"
    cpu: 8
    dx_instance_type: "mem3_ssd1_v2_x8"
  }
}

