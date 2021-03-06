#!/usr/bin/env Rscript


rm(list=ls(all=TRUE))


# source directory (just for internal testing, will be overwritten)
DIR <- file.path("/media/data/huber/Documents/WORKNEW/gwModBac")


##--- general parameters
source("parameters.R")   # read all the model parameters

##--- ARGUMENTS
#args <- c("simulations/sim001.yaml", "OK")
args <- commandArgs(trailingOnly <- TRUE)

# set directory based on the terminal line arguments supplied
initialOptions <- commandArgs(trailingOnly = FALSE)
fname <- "--file="
scriptName <- sub(fname, "", initialOptions[grep(fname, initialOptions)])
DIR <- dirname(scriptName)
if(!dir.exists(DIR)){
  stop(paste0("This directory (", DIR, ") does not exist!\n"))
}else{
  setwd(DIR)
  getwd()
}

# read configuration file
if(length(args) >= 1){
  configPath <- as.character(args[1])
  if(file.exists(configPath)){
    ppp <- configr::read.config(configPath)
  }else{
    stop("Couldn't find the config file!!")
  }
}else{
  stop("missing argument!!")
}




modGrid$nx <- ppp$modGrid$nx
modGrid$ny <- ppp$modGrid$ny
modGrid$nz <- ppp$modGrid$nz
modGridRef <- modGrid
modGridRef$nx <- ppp$modGridRef$nx
modGridRef$ny <- ppp$modGridRef$ny
modGridRef$nz <- ppp$modGridRef$nz

##--- some checks
if(modGrid$nx > modGridRef$nx) stop("modGrid$nx must be <=  modGridRef$nx\n")
if(modGrid$ny > modGridRef$ny) stop("modGrid$ny must be <=  modGridRef$ny\n")
if(modGrid$nz > modGridRef$nz) stop("modGrid$nz must be <=  modGridRef$nz\n")



##------ load/install packages
pckgs <- c("zoo", "compiler", "signal", "RandomFields", "akima", "rgdal",
           "raster", "rgeos", "devtools", "Cairo")
inst_pckgs <- pckgs[ !(pckgs %in% installed.packages()[,"Package"]) ]
if(length(inst_pckgs) > 0) install.packages(inst_pckgs)
pkgs_loaded <- lapply(c(pckgs), require, character.only = TRUE)
if(!require("devtools")) install.packages("devtools")
suppressMessages(devtools::install_github("emanuelhuber/GauProMod"))
require(GauProMod)

invisible(enableJIT(3))

source("fx/RMODFLOW.R")
source("fx/utilityFunctions.R")

pfx <- format(Sys.time(), "%Y_%m_%d_%H%M%S")


#---- directory project ----#
dirProj <- file.path(getwd(), ppp$projectName)
if(!dir.exists(dirProj)) dir.create(path = dirProj)


##-------------------------------- READ DATA ------------------------------##
timeID <- as.character(read.table("data/timeID.txt", sep = ",", header = FALSE,
                                  stringsAsFactors = FALSE))
# OBSERVATIONS
obs <- list()
# river
obs$riv$h <- read.zoo(file = "data/riverStage.txt", sep =",", header = FALSE, 
                      stringsAsFactors =FALSE, format=c("%d.%m.%y"), 
                      FUN = as.POSIXct)
obs$riv$pos <- as.vector(read.table("data/riverStageStation.txt", sep = ",", 
                          header = TRUE, stringsAsFactors = FALSE))
# groundwater
obs$gw$h <- as.matrix(unname(read.table("data/gwHeads.txt", sep = ",", 
                             header = FALSE, stringsAsFactors = FALSE)))
obs$gw$pos <- as.matrix(read.table("data/gwHeadStations.txt", sep = ",", 
                          header = TRUE, stringsAsFactors = FALSE))
weatherFor <- read.zoo(file = "data/weatherFor.txt", sep =",", header = FALSE, 
                      stringsAsFactors =FALSE, format=c("%d.%m.%y"), 
                      FUN = as.POSIXct)
precRef <- read.zoo(file = "data/precRef.txt", sep =",", header = FALSE, 
                      stringsAsFactors =FALSE, format=c("%d.%m.%y"), 
                      FUN = as.POSIXct)


# forecast time steps
timeForc <- (nstp - nstp_pred + 1):nstp
timePast <- 1:(nstp - nstp_pred)
timeIDFor <- timeID[timeForc]
timeIDPast <- timeID[timePast]


##--------------------------- SPATIAL DISCRETISATION -------------------------##
##--- model grid
b <- obs$riv$pos[,"z"] - (-river$slope) * obs$riv$pos[,"y"]
gwMod <- modGrid3D(modGrid, prec = 2, fun = valleyFloor, a = -river$slope, 
                  b = b)
pz_layer1 <-  0.4 # elevation layer 1 = gwMod[[1]] + pz_layer1
gwMod[[1]] <- gwMod[[1]] + pz_layer1
#plot(gwMod[[3]])

##--- river raster
rivPoly <- SpatialPolygons(list(Polygons(list(Polygon(river$perimeter)), 
                           "p1")), 1L)
# rRiv <- rasterize(rivPoly, gwMod[[1]])
rRiv <- rasterizePolygon(rivPoly, gwMod[[1]])
names(rRiv) <- "river"
gwMod <- stackRaster(gwMod, rRiv)
#plot(rRiv)
rm(rRiv)

##--- CHD raster
rCHD <- gwMod[[1]]
rCHD[] <- NA
rCHD[c(1,nrow(rCHD)),] <- 1
rCHD[!is.na(gwMod[["river"]])] <- NA
names(rCHD) <- "CHD"
gwMod <- stackRaster(gwMod, rCHD)
rm(rCHD)
# plot(gwMod[["CHD"]])
# rect(grid$W["min"], grid$L["min"], grid$W["max"], grid$L["max"])

##------------------------------ BOUNDARY CONDITIONS -------------------------##
##--- drinking water extraction Well
wellFrame <- setWells(gwMod, val = wellExt, timeID)
wellFrame[,timeID[1:7]] <- 0  # well off the first 7 days

##--- River
cellsRiv <- cellsFromExtent(gwMod[["river"]], trim(gwMod[["river"]])) 
#--- river bed elevation
xyRiv <- xyFromCell(gwMod[["river"]], cellsRiv)
rivBedAppz <- b + (-river$stepS) * xyRiv[,"y"] +  0.4 - 0.1
rivBedz0 <- rivBedAppz + floor( xyRiv[,"y"] /river$stepL ) * river$stepH 
rivBedz <- rivBedz0 - river$depth

# plot(xyRiv[,"y"], gwMod[[1]][cellsRiv], type="l", asp = 5)
# lines(xyRiv[,"y"],rivBedz0, col="grey", lty=3)
# lines(xyRiv[,"y"], rivBedz, col = "red")
# lines(xyRiv[,"y"], rivBedz + river$minStage, col = "blue")

#--- riverbed conductance
Cr0 <- (10^runif(length(cellsRiv),-3,-1) )
Cr <- Cr0 * res(gwMod)[1]*res(gwMod)[2]/river$bedT
#gwMod[["river"]][cellsRiv] <- rivBedz
riverFrame <- rivGwMod(gwMod, hrel = obs$riv$h, 
                       rivH0z = rivBedz + river$minStage, 
                       rivBedz = rivBedz, 
                       Cr = Cr*cst_mps2mpd, timeID = timeID)

##--- CHD
rowColCHD <- rowColFromCell(gwMod[["CHD"]], 
                            which(!is.na(values(gwMod[["CHD"]]))))
xyCHD <- xyFromCell(gwMod[["CHD"]], which(!is.na(values(gwMod[["CHD"]]))))
idCells <- cellFromRowCol(gwMod, rowColCHD[,"row"], rowColCHD[,"col"])
zl <- as.vector(extract(gwMod[["lay1.top"]], idCells))
ZCHD <- matrix(zl, nrow = length(idCells), ncol = length(timeID), byrow = FALSE)
zlbot <- as.vector(extract(gwMod[[paste0("lay",nlay(gwMod),".bot")]], xyCHD))
ZCHDbot <- matrix(zlbot, nrow=nrow(xyCHD),ncol=nstp,byrow=FALSE)


##-------------------------------- OBSERVATIONS ------------------------------##
##--- River observations
rowColRiv <- rowColFromCell(gwMod[["river"]], cellsRiv)
colnr <- max(rowColRiv[,2])
subSplRiv <- round(seq(1, to = nrow(gwMod[["river"]]),length.out = nrivObs))
rivVal <- t(riverFrame[riverFrame$col == colnr, timeID][subSplRiv,])
xyRivVal <-  xyFromCell(gwMod[["river"]], cellFromRowCol(gwMod[["river"]], 
                        rownr = subSplRiv, colnr = colnr))
xyRivVal[,"x"] <- xyRivVal[,"x"] + res(gwMod)[1]/2

# Boundary condition derivative for GP simulation
bc <- list(x = cbind(rep(xmax(gwMod),nbc) - res(gwMod)[1],
                    seq(from = ymin(gwMod) + res(gwMod)[2], 
                        to   = ymax(gwMod) - res(gwMod)[2],
                        length.out = nbc)),
           v = cbind(rep(1,nbc),
                    rep(0,nbc)),
           y =  rep(0,nbc),
           sigma = 0)

##-------------- PARTICLES - Bacteria infiltration into aquifer --------------##
xyExt <- xyFromCell(gwMod[[1]], cellFromXY(gwMod[[1]], 
                    xy = c(wellExt$x, wellExt$y)))
wellExt$x <- xyExt[1,1]
wellExt$y <- xyExt[1,2]
xyzExtWellFor <- zylParticles(co = xyExt, ro = 0.20, 
                              n=wellExtPart$nxy, zbot=wellExt$zbot, 
                              ztop=wellExt$ztop, npz=wellExtPart$nz)
partFor <- vector(mod="list",length=length(wellExtPart$t))
for(i in seq_along(wellExtPart$t)){
  partFor[[i]] <- setParticles(gwMod, xyzExtWellFor, 
                                releaseTime=wellExtPart$t[i])
}

##----------------------- MONTE CARLO SAMPLING -------------------------------##
numOfSim <- 1
# Cw <- matrix(0, nrow = numOfSim, ncol = length(timeForc))
# it <- 0                            # start at iteration it

cat("***** SIMULATION ******\n")
cat(format(Sys.time(), "   %Y/%m/%d %H:%M:%S \n"))
  

dirRun <- file.path(dirProj, ppp$simName)
suppressWarnings(dir.create(path = dirRun))


##------------------- HYDRAULIC PROPERTIES SIMULATION -----------------------#
##---- hyd. properties
# hydraulic conductivity
# if(!is.null(mySeed)){
if(ppp$GPHK$para){
  K_mean <- 10^ppp$GPHK$K_mean
  K_sd   <- ppp$GPHK$K_sd     # m/s
  ##--- covariance model
  # horizontal anisotropy angle
  K_hani <- ppp$GPHK$K_hani         
  # streching ratio horizontal
  K_hstr <- ppp$GPHK$K_hstr
  # streching ratio vertical
  K_vstr <- ppp$GPHK$K_vstr
  # smoothness parameter Matern cov
  K_nu   <- ppp$GPHK$K_nu
  # correlation length
  K_l    <- ppp$GPHK$K_l            
  # nugget sd
  K_nug   <- ppp$GPHK$K_nu
  gwModRef <- modGrid3D(modGridRef, prec = 2, fun = valleyFloor, 
                        a = -river$slope, b = b)
  gwModRef[[1]] <- gwModRef[[1]] + pz_layer1
  gwMod <- suppressMessages(suppressWarnings(
                gpHKgwModMultiScale(gwMod, K_hani, K_hstr, 
                                    K_vstr, K_nu, K_sd,
                                    K_l, K_nug, K_mean, 
                                    cst_mps2mpd, gwModRef )))
}else{
  # write.table(as.vector(K), file = "HK.txt", row.names = FALSE, col.names = FALSE)
  # Knew <- array(as.vector(K), dim = c(modGrid$ny, modGrid$nx, modGrid$nz))
  K <- as.matrix(read.table(ppp$GPHK$file))
  if(length(K) != (nrow(gwMod) * ncol(gwMod) * nlay(gwMod))){
    stop(paste0("GHPK file should have length = ", 
                nrow(gwMod) * ncol(gwMod) * nlay(gwMod),
                " (i.e., ", nrow(gwMod), " x ", ncol(gwMod), 
                  " x ", nlay(gwMod),")"))
  }
  K2 <- array(K, dim = c(nrow(gwMod), ncol(gwMod), nlay(gwMod)))
  for(i in 1:nlay(gwMod)){
    r <- gwMod[[1]]
    r[] <- K2[,,i] * cst_mps2mpd
    r[is.na(gwMod[[paste0("lay", i, ".bot")]])] <- NA
    names(r) <- paste0("lay", i, ".hk")
    gwMod <- stackRaster(gwMod, r)
  }
}

#--- porosity
gwMod <- porosity(gwMod, ppp$poro)    # porosity
#--- Zonation for "ss" and "sy"
att.table <- as.data.frame(list(ID = 1, 
                                ss = ppp$ss,   # specific storage
                                sy = ppp$sy))  # specific yield
gwMod <- zonation(gwMod, att.table)
# riverbed conductance m2/s
Cr0    <- 10^ppp$Cr0
Cr     <- Cr0 * res(gwMod)[1]*res(gwMod)[2]/river$bedT
riverFrame[,"cond"] <- Cr * cst_mps2mpd
##--------------------------------------------------------------------------##

##------------------- BOUNDARY CONDITION SIMULATION ------------------------##
##--- Forcasting river stage and groundwater heads (10-day ahead)
hfor <- forecastModel(rivh = as.numeric(riverFrame[1, timeIDPast]),
                      prec = as.numeric(precRef),
                      gwh  = obs$gw$h[, timePast],
                      weatherFor = weatherFor, convMod = convMod)

riverFrame[, timeIDFor] <- matrix(hfor$riv[timeForc], 
                                  nrow = nrow(riverFrame),
                                  ncol = length(timeForc), byrow = TRUE) -
                          (riverFrame[1, timeID[1]] - riverFrame[, timeID[1]])
##--- Specified head boundary conditions simulation (Gaussian Process)
rivVal <- t(riverFrame[riverFrame$col == colnr, timeID][subSplRiv,])
hobs   <- list("x" = rbind(obs$gw$pos[,1:2], xyRivVal), 
               "y" = c(as.vector(t(hfor$gw)), as.vector(unlist(rivVal))),
               "t" = seq_along(timeID))
#---- boundary: CHD ----#
tryAgain <- TRUE
while(tryAgain){

  covModel <- list(kernel = "matern",        
                   l      = ppp$GPBC$h_lx,
                   v      = ppp$GPBC$h_vx,
                   h      = ppp$GPBC$h_hx,
                   scale  = c(2,1))
  covModelTime <- list(kernel = "gaussian",
                       l      = ppp$GPBC$h_lt,
                       h      = ppp$GPBC$h_ht)
  covModels <- list(pos = covModel, time = covModelTime)
  GPCHD <- suppressWarnings(gpCond(obs = hobs, targ = list("x" = xyCHD), 
                            covModels = covModels,
                            sigma = ppp$GPBC$h_sig, op = 2, bc = bc ))
  L <- cholfac(GPCHD$cov)
  hCHD <- suppressWarnings(gpSim(GPCHD , L = L))
  colnames(hCHD) <- c("x","y","t","value")
  valCHD <- matrix(hCHD[,"value"], nrow=nrow(rowColCHD), ncol=nstp, 
                  byrow=TRUE)
  testCHD <- sum(valCHD >= ZCHD) + 
                sum(valCHD <= ZCHDbot)
  cat("   ")
  if(testCHD > 0){
    cat("+ ")
    next
  }else{
    #---STARTING HEADS
    hinit <- akima::interp(x = xyCHD[,1], y= xyCHD[,2], z = valCHD[,1], 
                      xo = xaxis(gwMod), yo = yaxis(gwMod), linear = TRUE)
    rStrH <- gwMod[[1]]
    rStrH[] <- as.vector(hinit$z)
    rStrH[!is.na(gwMod[["river"]])] <- riverFrame[,timeID[1]]
    if(any((gwMod[["lay1.top"]][] - rStrH[]) < 0) ){
      cat("  +  ")
      next
    }else{
      tryAgain <- FALSE
    }
  }
}
CHDFrame <- corCHD(gwMod, rowColCHD, valCHD, timeID)
gwMod <- initialHeads(gwMod, rStrH)
##--------------------------------------------------------------------------##

##--------------------------- MODFLOW SIMULATION ---------------------------##
idMF <- "simBC"     # ID MODFLOW model 
wetting <- c("wetfct" = 0.1 , "iwetit" = 5  , "ihdwet" = 0, "wetdry"= 0.8)
arguments <- list(rs.model = gwMod, 
                     well = wellFrame, 
                     river = riverFrame,
                       chd = CHDFrame,
                        id = idMF, 
                   dir.run = dirRun, 
                 ss.perlen = 5L, 
         tr.stress.periods = as.Date(timeID[-1], timeFormat),
                   wetting = wetting,
            is.convertible = TRUE,
                       uni = uni,
                timeFormat = timeFormat)
suppressMessages(do.call(WriteModflowInputFiles, arguments))
cat("Run MODFLOW...")
A <- runModflowUsg(dirpath = dirRun, id = idMF, exe = "mfusg")

#--- check!
if(!any(grepl("normal termination", A, ignore.case=TRUE))){
  cat("MODFLOW failed!!\n")
  # it <- it-1
  unlink(dirRun, recursive=TRUE, force=TRUE)
  next
}
cat("... OK!\n")
##..........................................................................##

#   heads.info(fHeads)

##.............. MODPATH SIMULATION - BACTERIA INFILTRATION ................##
idMP2 <- "bacteria"
suppressMessages(writeModpathInputFiles( id             = idMP2,
                       dir.run         = dirRun,
                       optionFlags     = c("StopOption"          = 2, 
                                           "WeakSinkOption"      = 1,
                                           "WeakSourceOption"    = 2,
                                           "TrackingDirection"   = 2,
                                           "ReferenceTimeOption" = 1), 
                       budgetFaceLabel = NULL, 
                       fbud            = file.path(dirRun, 
                                                   paste0(idMF,".bud")),
                       rs.model        = gwMod,
                       particles       = partFor,
                       ReferenceTime   = nstp,
                       unconfined      = TRUE,
                       verbose         = FALSE))
cat("   Run MODPATH...")
B <- runModpath(dirpath = dirRun, id = idMP2, exe = "mp6", 
                batFile = "runModpath.bat")

if(is.null(B) || !any(grepl("normal termination", B, ignore.case=TRUE))){
  cat("MODPATH (2) failed!!\n")
  # it <- it-1
  unlink(dirRun, recursive=TRUE, force=TRUE)
  next
}
#   ext <- extent3D(gwMod)
#   Pend <- readParticles(idMP2, dirRun, r = gwMOD, type="end")
#   Ppath <- readParticles(idMP2, dirRun, r = gwMOD, type="path")

Pend <- readParticles(idMP2, dirRun, type="end")
Ppath <- readParticles(idMP2, dirRun,  type="path")

if(all(Pend[,"iLay"] == Pend[,"fLay"] &&
       Pend[,"iRow"] == Pend[,"fRow"] &&
       Pend[,"iCol"] == Pend[,"fCol"])){
  cat("MODPATH (2) > particles did not move!!\n")
  # it <- it-1
  unlink(dirRun, recursive=TRUE, force=TRUE)
  next
}
cat("... OK!\n")
##..........................................................................##

##.............. SIMULATION MICROBES CONCENTRATION IN WELL .................##
Cw <- microbesSim(r = gwMod[["river"]], Pend = Pend,
                        Ppath = Ppath, rivh = hfor$riv, 
                        a = bactConcPara$a, b = bactConcPara$b, d = 100, 
                        span = 0.4, lambda = bactConcPara$lambda)
##..........................................................................##

if(isTRUE(ppp$plot)){
  fHeads <- file.path(dirRun , paste0(idMF , ".hds"))
  rHeads <- get.heads(fHeads, kper = 1:nstp, kstp = 1, r = gwMod[[1]])
  hi <- paste0("lay1.head.1.", length(timeID))
  
  nt <- length(hfor$riv)
  timeC <- unique(nt + 1 - Pend[,"iTime"])
  # 1. identify particles coming from the river
  test <- extract(gwMod[["river"]], Pend[,c("x","y")], method = "bilinear")
  vtest <- (!is.na(test) & !is.na(Pend[,c("z")]))

  ids <- unique(Ppath[,"id"])
  if(length(ids) > 500){
    ids <- ids[sample.int(n = length(ids), size = 500)]
  }
  polyRiv <- rasterToPolygons(gwMod[["river"]], dissolve=TRUE)
  png(filename = paste0(dirRun, ".png"), 
          width = 480, height = 860, pointsize = 12)
    plot(rHeads[[hi]])
    contour(rHeads[[hi]], levels=seq(0,30,by=0.05), add=TRUE)
    sp::plot(polyRiv, col = rgb(145/255, 238/255, 1, 150/255), add = TRUE)
    plotPathXY(Ppath, id = ids)
    points(Pend[vtest,c("x","y")] ,pch=20,col="black", cex = 1.5) 
    points(Pend[vtest,c("x","y")] ,pch=20,col="green", cex = 0.5) 
    points(Pend[!vtest,c("x","y")] ,pch=20,col="red", cex = 1)
    points(wellExt["x"],wellExt["y"], pch=22, bg="blue",cex=1)
    title(tail(timeID, 1))
  dev.off()

}
cat("   Concentration = ", format(Cw, 12, scientific = TRUE), "\n")
unlink(dirRun, recursive=TRUE, force=TRUE)


write.table(format(Cw, 12, scientific = TRUE), 
            file = paste0(dirRun, ".txt"), append = FALSE, quote = FALSE, sep = "\t", 
            col.names = FALSE, row.names = FALSE)

#   plot(gwMod[["river"]])
#   plotPathXY(Ppath[Ppath[,"id"] %in% 
#                       Pend[which(!is.na(test2)),"id"],])
#   plot(gwMod[["river"]])
#   plotPathXY(Ppath[Ppath[,"id"] %in% 
#                       Pend[which(!is.na(test)),"id"],])
#   
#   
#   plotPathXY(Ppath[which(!is.na(test2)),])
# 
# 
#  
#  
#    fHeads <- file.path(dirRun , paste0(idMF , ".hds"))
#   rHeads <- get.heads(fHeads, kper = 1:nstp, kstp = 1, r = gwMod[[1]])
#   CairoPNG(filename = file.path(dirProj, 
#             paste0(simName,"_", length(timeID), "_.png")), 
#             width = 480, height = 860, pointsize = 12)
#     hi <- paste0("lay2.head.1.", length(timeID))
#     plot(rHeads[[hi]])
#     contour(rHeads[[hi]], levels=seq(0,30,by=0.05), add=TRUE)
#     points(Pend[,c("x","y")],pch=20,col="blue")  # end (final)
#     plotPathXY(Ppath)
#     plotPathXY(Ppath)
#     points(wellExt["x"],wellExt["y"], pch=22, bg="green",cex=1)
#     title(tail(timeID, 1))
#   dev.off()
#   
#   plot(gwMod[["river"]])
