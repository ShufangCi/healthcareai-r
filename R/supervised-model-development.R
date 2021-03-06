#' Compare predictive models, created on your data
#'
#' @description This step allows one to create test models on your data
#' and helps determine which performs best.
#' @docType class
#' @usage SupervisedModelDevelopment(object)
#' @import caret
#' @importFrom R6 R6Class
#' @param object of SuperviseModelParameters class for $new() constructor
#' @references \url{http://healthcare.ai}
#' @seealso \code{\link{healthcareai}}
#'
#' @export

SupervisedModelDevelopment <- R6Class("SupervisedModelDevelopment",

  #Private members
  private = list(

    ###########
    # Variables
    dfTrain = NA,
    dfTest = NA,
    dfGrain = NA,
    grainTest = NA,
    prevalence = NA,

    clustersOnCores = NA,
    grainColValues = NA,

    # Creating attributes for performance report
    memsizeOfDataset = NA,
    initialDatasetRows = NA,
    initialDatasetCols = NA,

    ###########
    # Functions

    registerClustersOnCores = function() {
      if (self$params$cores > 1) {
        suppressMessages(library(doParallel))
        private$clustersOnCores <- makeCluster(self$params$cores)
        registerDoParallel(private$clustersOnCores)
      }
    },

    stopClustersOnCores = function() {
      if (self$params$cores > 1) {
        stopCluster(private$clustersOnCores)
        registerDoSEQ()
      }
    },

    #Set config parameters for the algorithm
    setConfigs = function(p) {

      self$params <- SupervisedModelDevelopmentParams$new()

      if (!is.null(p$df))
        self$params$df <- p$df

      if (!is.null(p$grainCol))
        self$params$grainCol <- p$grainCol

      if (!is.null(p$predictedCol))
        self$params$predictedCol <- p$predictedCol

      if (!is.null(p$personCol))
        self$params$personCol <- p$personCol

      if (!is.null(p$groupCol))
        self$params$groupCol <- p$groupCol

      if (!is.null(p$type) && p$type != '') {
        self$params$type <- p$type

        # validation on type string values
        if (self$params$type != 'regression' && self$params$type != 'classification' && self$params$type != 'multiclass') {
          stop('Your type must be regression, classification, or multiclass')
        }
        if (self$params$type =='classification' && isBinary(self$params$df[[self$params$predictedCol]]) == FALSE){
          stop('Dependent variable must be binary for classification')
        }
        if (self$params$type =='regression' && isBinary(self$params$df[[self$params$predictedCol]]) == TRUE){
          stop('Dependent variable cannot be binary for regression')
        }
      }

      if (!is.null(p$impute))
        self$params$impute <- p$impute

      if (!is.null(p$debug))
        self$params$debug <- p$debug

      if (!is.null(p$varImp))
        self$params$varImp <- p$varImp

      if (!is.null(p$printResults))
        self$params$printResults <- p$printResults

      if (!is.null(p$cores))
        self$params$cores <- p$cores

      if (!is.null(p$xgb_params))
        self$params$xgb_params <- p$xgb_params

      #Set additional settings
      if (isTRUE(self$params$debug)) {
        print('Training data set immediately before training')
        print(str(private$dfTrain))
      }

      #Set up clusters on cores
      private$registerClustersOnCores();
    },

    #Load data
    loadData = function() {

      # init dataset variables
      private$memsizeOfDataset <- format(object.size(self$params$df), 
                                         units = "Mb")
      private$initialDatasetRows <- nrow(self$params$df)
      private$initialDatasetCols <- ncol(self$params$df)

      # For use in confusion matrices
      private$prevalence <- table(self$params$df[[self$params$predictedCol]])[2]

      if (length(returnColsWithMoreThanFiftyCategories(self$params$df)) > 0) {
        warning('These columns in the df have more than fifty categories: \n',
                paste(
                 shQuote(returnColsWithMoreThanFiftyCategories(self$params$df)), 
                 collapse = ", "),
                 '\n This drastically reduces performance. \n',
                 'Consider combining into new col with fewer categories.')
      }

      if (isTRUE(self$params$debug)) {
        print('Entire data set at the top of the constructor')
        print(str(self$params$df))
      }

      if (isTRUE(self$params$debug)) {
        print('Entire df after removing cols with DTS')
        print(str(self$params$df))
        print('Now going to remove zero-var cols...')
      }

      # Remove columns with zero variance
      self$params$df <- removeColsWithAllSameValue(self$params$df)

      if (isTRUE(self$params$debug)) {
        print('Entire df after removing feature cols w/zero var')
        print(str(self$params$df))
      }

      # For multiclass xgboost initialization:
      # 1. Save the class names before they are converted.
      # 2. Get the number of classes.
      # 3. Save the grain column for output.
      if (self$params$type == 'multiclass' ) {
        # Names
        ind <- grep(self$params$predictedCol, colnames(self$params$df))
        tempCol <- self$params$df[,ind]
        self$params$xgb_targetNames <- sort(unique(tempCol))
        # Number
        self$params$xgb_numberOfClasses <- length(self$params$xgb_targetNames)
        self$params$xgb_params$num_class <- self$params$xgb_numberOfClasses
        # Grain
        private$dfGrain <- self$params$df[[self$params$grainCol]]
        rm(ind, tempCol)
        # prints
        if (isTRUE(self$params$debug)) {
          print('Unique classes found:')
          print(self$params$xgb_targetNames)
          print('Number of classes:')
          print(self$params$xgb_numberOfClasses)
        }
      }


      # Convert to data.frame (in case of data.table)
      # This also converts chr cols to (needed) factors
      self$params$df <- as.data.frame(unclass(self$params$df))

      if (isTRUE(self$params$debug)) {
        print('Entire data set after converting to df and chr to factor')
        print(str(self$params$df))
      }

      if (isTRUE(self$params$impute)) {
        self$params$df[] <- lapply(self$params$df, imputeColumn)

        if (isTRUE(self$params$debug)) {
          print('Entire data set after imputation')
          print(str(self$params$df))
        }

      } else {
        if (isTRUE(self$params$debug)) {
          print(paste0("Rows in data set before removing rows with NA's: ", nrow(self$params$df)))
        }

        # Remove rows with any NA's
        self$params$df <- na.omit(self$params$df)

        if (isTRUE(self$params$debug)) {
          print(paste0("Rows in data set after removing rows with NA's: ", nrow(self$params$df)))
          print("Entire data set after removing rows with NA's")
          print(str(self$params$df))
        }
      }

      # Remove columns that are only NA
      self$params$df <- self$params$df[,colSums(is.na(self$params$df)) < nrow(self$params$df)]

      # Remove date columns
      dateList <- grep("DTS$", colnames(self$params$df))
      if (length(dateList) > 0) {
        self$params$df <- self$params$df[, -dateList]
      }

      if (isTRUE(self$params$debug)) {
        print('Entire data set after removing cols with DTS (ie date cols)')
        print(str(self$params$df))
        print('Now going to remove grainCol...')
      }

      # For rf/lasso, remove grain col (if specified)
      # For LMM, don't remove grain col even if specified--note personCol
      if ((nchar(self$params$grainCol) != 0) & (nchar(self$params$personCol) == 0)) {
        private$grainColValues <- df[[self$params$grainCol]]
        self$params$df[[self$params$grainCol]] <- NULL
      }

      if (isTRUE(self$params$debug) && nchar(self$params$grainCol) != 0) {
        print('Entire data set after separating out grain col')
        print(str(self$params$df))
        print('Now splitting training set from validation set')
      }

      #Declare that the predicted col is a factor, or category to be predicted.
      if (self$params$type == 'classification' || self$params$type == 'multiclass' ) {
        self$params$df[[self$params$predictedCol]] = as.factor(self$params$df[[self$params$predictedCol]])
      }

      trainIndex <- createDataPartition(y = self$params$df[[self$params$predictedCol]],
                                       p = 0.8,
                                       list = FALSE, times = 1)

      private$dfTrain <- self$params$df[ trainIndex,]
      private$dfTest  <- self$params$df[-trainIndex,]
      private$grainTest  <- private$dfGrain[-trainIndex] # Save grain for xgboost output
      self$trainIndex <- trainIndex

      if (isTRUE(self$params$debug)) {
        print('Training data set after splitting from main df')
        print(str(private$dfTrain))
      }

      if (isTRUE(self$params$debug)) {
        print('Validation data set after splitting from main df')
        print(str(private$dfTest))
      }

      # Remove rows where predicted.col is null in train
      private$dfTrain <- removeRowsWithNAInSpecCol(private$dfTrain,
                                                  self$params$predictedCol)

      if (isTRUE(self$params$debug)) {
        print('Training data set after removing rows where pred col is null')
        print(str(private$dfTrain))
      }
    }
  ),

  #Public members
  public = list(

    ###########
    # Variables

    #parameters
    params = NA,
    trainIndex = NA,

    ###########
    # Functions

    #Constructor
    #p: new SupervisedModelDevelopmentParams class object,
    #   i.e. p = SuperviseModelParams$new()
    initialize = function(p) {

      #Set config parameters
      private$setConfigs(p)

      #Load data
      private$loadData()
    },

    #Build the Model
    buildModel = function() {
    },

    #Run the Model for Prediction
    run = function() {
    }
  )
)
