#' runAlign
#'
#' Runs the preprocessing methods for single-molecule data on sequences.
#'
#' @param ref A reference sequence
#' @param fasta A list of sequences
#' @param fasta.subset A vector of indices indicating which sequences to process.
#' @param multicoreParam A MulticoreParam object, used to align sequences in parallel.
#' @param updateProgress Used to add a progress bar to the Shiny app. Should not be used otherwise.
#' @param log.file String indicating where to save a log of the alignment process. If left NULL, no log is saved.
#'
#' @importFrom Biostrings DNAString DNA_ALPHABET reverseComplement pairwiseAlignment score alignedPattern alignedSubject
#' @importFrom seqinr c2s s2c read.fasta
#' @importFrom BiocParallel bplapply
#' @export
runAlign <- function(ref, fasta, fasta.subset = (1:length(fasta)),
                     multicoreParam = NULL, updateProgress = NULL, log.file = NULL)
{
  fasta <- fasta[fasta.subset]
  ref.string <- DNAString(toupper(c2s(ref[[1]])))

  log.vector <- c("Beginning preprocessing")

  if (is.function(updateProgress)) updateProgress(message = "Aligning sequences", value = 0.1)
  alignment.out <- alignSequences(fasta, ref.string, log.vector, multicoreParam, updateProgress)

  alignedseq <- alignment.out$alignedseq
  log.vector <- alignment.out$log.vector


  if (is.function(updateProgress)) updateProgress(message = "Identifying sites", value = 0.75)
  # We want to avoid GCG sites:
  GCsites <- gregexpr("GC",c2s(ref.string),fixed=TRUE)[[1]] + 1
  CGsites <- gregexpr("CG",c2s(ref.string),fixed=TRUE)[[1]]

  log.vector <- c(log.vector, paste("Throwing out", length(which(s2c(paste(ref.string))[GCsites+1] == "G")) +
                                    length(which(s2c(paste(ref.string))[CGsites-1] == "G")), "GCG sites"))

  CGsites <- CGsites[which(s2c(paste(ref.string))[CGsites-1] != "G")]
  GCsites <- GCsites[which(s2c(paste(ref.string))[GCsites+1] != "G")]

  if (is.function(updateProgress)) updateProgress(message = "Mapping sites", value = 0.8)


  if (is.null(multicoreParam))
  {
    gcmap <- lapply(alignedseq, mapseq, sites=GCsites)
    cgmap <- lapply(alignedseq, mapseq, sites=CGsites)
  } else {
    gcmap <- bplapply(alignedseq, mapseq, sites=GCsites, BPPARAM = multicoreParam)
    cgmap <- bplapply(alignedseq, mapseq, sites=CGsites, BPPARAM = multicoreParam)
  }

  if (is.function(updateProgress)) updateProgress(message = "Preparing matrices", value = 0.95)

  saveCG <- data.matrix(do.call(rbind, lapply(cgmap, function(x) (x))))
  saveCG <- cbind(rownames(saveCG), saveCG)

  saveGC <- data.matrix(do.call(rbind, lapply(gcmap, function(x) (x))))
  saveGC <- cbind(rownames(saveGC), saveGC)
  if (is.function(updateProgress)) updateProgress(message = "Done", value = 1)

  if (!is.null(log.file))
  {
      writeLines(log.vector, con=log.file)
  }

  return(list(hcg = saveCG, gch = saveGC))
}


# this handles the alignment of ALL the sequences, and returns the alignedseq object used in the runAlign function
# this needs the log.vector, multicoreParam, and updateProgress so that we can continue keeping track of these things
alignSequences <- function(fasta, ref.string, log.vector, multicoreParam = NULL, updateProgress = NULL)
{
    ## this creates the substitution matrix for use in alignment
    penalty.mat <- matrix(0,length(DNA_ALPHABET[1:4]),length(DNA_ALPHABET[1:4]))
    penalty.mat[1:4,1:4] <- c(1,0,1,0,0,1,0,0,0,0,1,0,0,1,0,1)
    penalty.mat[penalty.mat==0] <- -5
    penalty.mat <- cbind(penalty.mat, c(0,0,0,0))
    penalty.mat <- rbind(penalty.mat, c(0,0,0,0,1))
    rownames(penalty.mat) <- colnames(penalty.mat) <- c(DNA_ALPHABET[1:4], "N")

    if (is.null(multicoreParam)) seqalign.out <- lapply(1:length(fasta), function(i) {

        if (is.function(updateProgress)) updateProgress(message = "Aligning seqences",
                                                       detail = paste(i, "/", length(fasta)),
                                                       value = (0.1+ 0.65/length(fasta) * i))
        seqalign(fasta[[i]], ref.string, substitutionMatrix = penalty.mat)
      }) else seqalign.out <- bplapply(1:length(fasta),
                                  function(i) seqalign(fasta[[i]], ref.string, substitutionMatrix = penalty.mat),
                                  BPPARAM = multicoreParam)
    useseqs <- sapply(seqalign.out, function(i) i$u)
    scores <- sapply(seqalign.out, function (i) i$score)
    maxAligns <- sapply(seqalign.out, function (i) i$maxAlign)

    score.cutoff.idx <- which.max(diff(sort(scores))) + 1
    score.cutoff <- sort(scores)[score.cutoff.idx]

    good.alignment.idxs <- which(scores > score.cutoff)

    alignedseq <- lapply(good.alignment.idxs, function(i){
        SEQ1 = s2c(paste(alignedPattern(useseqs[[i]])))
        SEQ2 = s2c(paste(alignedSubject(useseqs[[i]])))

        toreplace <- SEQ1[which(SEQ2=="-")]
        toreplace[toreplace!="C"] <- "."
        toreplace[toreplace=="C"] <- "." #or T?. Leave as "." for now.

        SEQ2[which(SEQ2=="-")] <- toreplace
        SEQ2 <- SEQ2[which(SEQ1!="-")]
        if (maxAligns[i] == 1) SEQ2 <- s2c(paste(reverseComplement(DNAString(c2s(SEQ2)))))

        SEQ2
    })
    log.vector <- c(log.vector, paste("Throwing out", length(useseqs) - length(good.alignment.idxs), "alignments"))

    names(alignedseq) <- names(fasta)[good.alignment.idxs]
    return(list(alignedseq = alignedseq, log.vector = log.vector))


}


# aligns a single read to the reference, returns the useseq string. Alignment is finished in the alignSequences fn
seqalign <- function(read, ref.string, substitutionMatrix) {

  fasta.string <- DNAString(toupper(c2s(read)))

  align.bb <- pairwiseAlignment(reverseComplement(ref.string),
                                reverseComplement(fasta.string),type="global-local", gapOpening=8, substitutionMatrix=substitutionMatrix)
  align.ab <- pairwiseAlignment(ref.string, reverseComplement(fasta.string),type="global-local", gapOpening=8, substitutionMatrix=substitutionMatrix)
  align.aa <- pairwiseAlignment(ref.string, fasta.string,type="global-local", gapOpening=8, substitutionMatrix=substitutionMatrix)

  maxAlign <- which.max(c(score(align.bb), score(align.ab), score(align.aa)))
  allseq <- list(align.bb, align.ab, align.aa)
  useseq <- allseq[[maxAlign]]

  return(list(u = useseq, score = score(useseq), maxAlign = maxAlign))
}

mapseq <- function(i, sites) {
  editseq <- i
  editseq[sites][editseq[sites] == "."] <- "T"
  editseq[sites][editseq[sites] == "T"] <- "-2"
  editseq[sites][editseq[sites] == "C"] <- "2"
  editseq[sites][editseq[sites] == "G"] <- "."
  editseq[sites][editseq[sites] == "A"] <- "."
  editseq[sites][editseq[sites] == "N"] <- "." # we need to make sure that the N sites stay marked with a "."
  missing_bp <- which(editseq == ".")

  sites.temp <- c(0, sites, length(editseq)+1)
  for (j in 1:(length(sites.temp)-1)) {
    tofill <- seq(sites.temp[j]+1,(sites.temp[j+1]-1))
    s1 <- editseq[pmax(1, sites.temp[j])]
    s2 <- editseq[pmin(length(i), sites.temp[j+1])]
    is.first <- (pmax(1, sites.temp[j]) == 1)

    if (s1 == "2" & s2 == "2") { fillvec <- 1 }
    else if (s1 == "2" & s2 == "-2") {fillvec <- 0}
    else if (s1 == "-2" & s2 == "2") {fillvec <- 0}
    else if (s1 == "-2" & s2 == "-2") {fillvec <- -1}
    else if (s1 == "." & s2 == "."){fillvec <- "."}
    else if (is.first & s2 == ".") {fillvec <- "."}
    else fillvec <- 0
    fillvec <- rep(fillvec, length(tofill))
    editseq[tofill] <- fillvec
    editseq[intersect(tofill, missing_bp)] <- "."
  }

  substring.table <- get_contig_substrings(editseq)
  long.missing <- which(substring.table$char == "." & substring.table$count > 3)
  short.non.missing <- which(substring.table$char == "-" & substring.table$count <= 20)
  short.non.missing.surrounded <- short.non.missing[(short.non.missing + 1) %in% long.missing | (short.non.missing - 1) %in% long.missing]
  counts <- as.numeric(substring.table$count)
  for (idx in short.non.missing.surrounded) # this part is tricky... we want to change the short non-missing sections to missing
  {
      if (idx == 1) editseq[1:counts[idx]] <- "."
      else
      {
          first <- sum(counts[1:(idx-1)]) + 1
          last <- first + counts[idx] - 1
          editseq[first:last] <- "."
      }
  }

  return(editseq)
}


## we want to be able to get all contiguous substrings of a certain string... in particular one of the editseq strings used above
## i want to return a table
get_contig_substrings <- function(s)
{
    ## we want some sort of table to keep track of the substrings
    substring.table <- data.frame(char = "a", count = 0)

    s <- ifelse(s == ".", ".", "-") ## use "-" to denote the non-missing ones... so we only keep track of missing and non missing
    i <- 1
    while (i <= length(s))
    {
        j <- i
        while(s[j] == s[i] & j <= length(s)) j <- j + 1
        substring.table <- rbind(substring.table, c(s[i], j - i))
        i <- j
    }
    substring.table <- data.frame(char = substring.table$char[-1], count = as.numeric(substring.table$count[-1]))
    return(substring.table)
}
