#' Download datasets
#' 
#' \code{get_data} downloads the full datasets per records. File paths are added to the records data frame.
#'
#' @inheritParams get_previews
#' @param md5_check logical, whether to check md5 checksums (if available) or not.
#' 
#' @note To use this function, you must be logged in at the services required for your request. See the examples and \link{login} for details.
#' @return A data frame of records (as defined with argument \code{records}), extended by additional columns.
#' 
#' @details
#' 
#' Sentinel data are downloaded from the *ESA Copernicus Open Access Hubs*.
#' 
#' Landsat data are downloaded from *USGS-EROS ESPA* (on-demand higher-level data) and *Amazon Web Services* (Landsat-8 Level 1 data).
#' 
#' MODIS data are downloaded from the Level-1 and Atmosphere Archive & Distribution System (LAADS) of NASA's Distributed Active Archive Center (DAAC) at the Goddard Space Flight Center in Greenbelt, Maryland (\url{https://ladsweb.modaps.eosdis.nasa.gov/}).
#' 
#' 
#' @author Jakob Schwalb-Willmann
#' 
#' @importFrom httr content
#' 
#' @name get_data
#' @export

get_data <- function(records, dir_out = NULL, md5_check = TRUE, force = FALSE, as_sf = TRUE, ..., verbose = TRUE){
  
  # check arguments
  if(inherits(verbose, "logical")) options(gSD.verbose = verbose)
  extras <- list(...)
  if(is.null(extras$hub)) extras$hub <- "auto"
  if(is.null(records$level)) records$level <- NA
  records <- .check_records(records, c("product", "product_group", "entity_id", "level", "record_id", "summary")) # should be product-specific!!!
  
  # save names
  records.names <- colnames(records)
  
  # login check
  groups <- unique(records$product_group)
  if("Sentinel" %in% groups){
    .check_login("Copernicus")
  }
  if("Landsat" %in% groups){
    .check_login("USGS")
  }
  if("MODIS" %in% groups){
    .check_login(c("USGS", "earthdata"))
  }
  if("SRTM" %in% groups){
    .check_login(c("earthdata"))
  }
  
  # check availability
  if(is.null(records$download_available)){
    out("Column 'download_available' not present, calling check_availabilty() to check download availability of records...")
    records <- check_availability(records, verbose = FALSE)
    if(inherits(verbose, "logical")) options(gSD.verbose = verbose)
  }
  if(all(!records$download_available)) out("All supplied records are currently not availabe for download. Use order_data() to make them available for download.", type = 3)
  if(any(!records$download_available)) out("Some records are currently not available for download and will be skipped (see records$download_available). Use order_data() to make them available for download.", type = 2)
  sub <- which(records$download_available)
  
  # check for ESPA records
  if(any(records[sub,][records$product_group == "Landsat",]$level != "l1")){
    records$gSD.espa_item <- NA
    records[sub,][records$product_group == "Landsat" & records$level != "l1",]$gSD.espa_item <- 
      .apply(records[sub,][records$product_group == "Landsat" & records$level != "l1",], MARGIN = 1, function(x){
      content(.get(paste0(getOption("gSD.api")$espa, "item-status/", x$order_id, "/", x$record_id), getOption("gSD.usgs_user"), getOption("gSD.usgs_pass")))[[1]][[1]]
    })
  }
  
  # get credendtial info
  records$gSD.cred <- NA
  records[sub,]$gSD.cred <- .apply(records[sub,], MARGIN = 1, function(x){
    
    if(x["product_group"] == "Sentinel"){
      list(.CopHub_select(x = extras$hub, p = if(isTRUE(as.logical(x[["is_gnss"]]))) "GNSS" else x[["product"]], user = getOption("gSD.dhus_user"), pw = getOption("gSD.dhus_pass")))
    } else if(x["product_group"] == "SRTM"){
      list(user = getOption("gSD.ed_user"), pw = getOption("gSD.ed_pass"))
    } else NA
  })
  
  # get MD5 checksums
  records$md5_checksum <- NA
  if(isTRUE(md5_check)){
    out("Receiving MD5 checksums...")
    records[sub,]$md5_checksum <- unlist(.apply(records[sub,], MARGIN = 1, function(x){
      
      if(x["product_group"] == "Sentinel"){
        cred <- unlist(x$gSD.cred)
        if(!is.null(x$md5_url)) content(.get(x$md5_url, cred[1], cred[2]), USE.NAMES = F) else NA
      
      } else if(x["product_group"] == "Landsat" & x$level != "l1"){
        strsplit(content(.get(x$gSD.espa_item$cksum_download_ur), as = "text", encoding = "UTF-8"), " ")[[1]][1]
      
      } else NA
    }, verbose = F))
  }
  
  # get URLs
  out("Assembling dataset URLs...")
  #records=as.data.frame(records)
  records$dataset_url <- NA
  records[sub,]$dataset_url <- .get_ds_urls(records[sub,])
  out(records$dataset_url)
  
  # create directories
  dir_out <- .check_dir_out(dir_out, "datasets")
  records$gSD.dir <- paste0(dir_out, "/", records$product, "/")
  catch <- .sapply(records$gSD.dir, function(x) if(!dir.exists(x)) dir.create(x, recursive = T))
  
  # file name
  records$dataset_file <- NA
  records[sub,]$dataset_file <- .get_ds_filenames(records[sub,])
  
  # items and head
  records$gSD.item <- 1:nrow(records)
  records$gSD.head <- .sapply(records$gSD.item, function(i, n = nrow(records)) paste0("[Dataset ", toString(i), "/", toString(n), "] "))
  
  # download file
  records$dataset_file <- .apply(records, MARGIN = 1, function(x){
    
    if(isTRUE(x$download_available)){
      dataset_url <- unlist(x$dataset_url, recursive = T)
      dataset_file <- unlist(x$dataset_file, recursive = T)
      cred <- unlist(x$gSD.cred)
      if(any(is.na(dataset_url), is.na(dataset_file))) NA else {
        
        # attempt download
        download <- .sapply(1:length(dataset_url), function(i){
          file.head <- gsub("]", paste0(" | File ", i, "/", length(dataset_url), "]"), x$gSD.head)
          .retry(.download,
                 url = dataset_url[i],
                 file = dataset_file[i],
                 name = paste0(x$record_id, if(!is.na(x$level)) paste0(" (", x$level, ")") else NULL), 
                 head = file.head,
                 type = "dataset",
                 md5 = x$md5_checksum,
                 prog = if(isTRUE(verbose)) TRUE else FALSE,
                 fail = expression(out(paste0("Attempts to download '", name, "' failed.", type = 2))),
                 retry = expression(out(paste0("[Attempt ", toString(3-n+1), "/3] Reattempting download of '", name, "'..."), msg = T)),
                 delay = 0,
                 value = T,
                 username = if(any(x$product_group == "Sentinel", x$product_group == "SRTM")) cred[1] else NULL,
                 password = if(any(x$product_group == "Sentinel", x$product_group == "SRTM")) cred[2] else NULL)
        })
        
        # return downloaded files
        files <- dataset_file[download]
        if(length(files) > 0) list(files) else return(NA)
      }
    } else{
      out(paste0(x$gSD.head, "Skipping download of dataset '", paste0(x$record_id, if(!is.na(x$level)) paste0(" (", x$level, ")") else NULL), "', since it is not available for download..."), msg = T)
      return(NA)
    }
  })
  
  records <- .check_records(records, as_sf = as_sf)
  return(.column_summary(records, records.names))
}


#' @rdname get_data
#' 
#' @export
getSentinel_data <- get_data

#' @rdname get_data
#' @export

getLandsat_data <- get_data

#' @rdname get_data
#' @export

getMODIS_data <- get_data
