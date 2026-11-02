# Introduction to R and RStudio

# Modified: 2025-10-20

# R is a programming language often used for statistical analysis,
# especially in bioinformatics. RStudio is a popular IDE for writing and running R code.

# This script will guide you through some basics of R and show examples
# of variables, data types, and basic operations.

# --------------------------------------------------------------
# R Syntax and Running Code
# --------------------------------------------------------------

# In R scripts, you can write code and run each line individually by placing
# your cursor on the line and pressing Ctrl+Enter (Windows) or Cmd+Enter (Mac).
# Comments are written using # and will not run as code.

# Basic calculation (this is a comment)
2 + 2

# --------------------------------------------------------------
# Variables
# --------------------------------------------------------------

# Creating a variable by assigning a value using <- or =
a <- 8 + 9
a

b = 1 + 9
b

# --------------------------------------------------------------
# Types, Classes, Modes
# --------------------------------------------------------------

# Different ways to check the properties of a variable
x <- 1
class(x)         # What type of object is it?
typeof(x)        # How R interprets it
mode(x)          # S language interpretation
storage.mode(x)  # How it's stored in memory

# Converting (casting) a variable's type
x <- as.character(x)
class(x)
typeof(x)

# --------------------------------------------------------------
# Logical Class (Boolean Values)
# --------------------------------------------------------------

# Logical values represent TRUE and FALSE, often used for conditional checks
a <- 5 == 5   # TRUE
b <- 5 != 5   # FALSE

# Logical operations
5 < 6          # TRUE
5 == 5 & 6 == 5   # FALSE (AND condition)
5 == 5 | 6 == 5   # TRUE (OR condition)

# Logical values can also be converted to numbers
as.numeric(TRUE)   # 1
as.numeric(FALSE)  # 0

# --------------------------------------------------------------
# Basic Math Operations
# --------------------------------------------------------------

# Arithmetic operations
5 + 5
10 - 9
11 / 2
2 * 2

# --------------------------------------------------------------
# Data Structures: Vectors
# --------------------------------------------------------------

# A vector is a sequence of elements of the same data type
v <- c(1, 2, 3)
v

# Basic math operations on vectors (element-wise)
vec1 <- c(5, 6, 7, 8)
vec2 <- c(2, 3, 4, 2)

vec1 + vec2
vec1 * vec2

# --------------------------------------------------------------
# Data Structures: Matrices
# --------------------------------------------------------------

# A matrix is a 2D structure that stores elements of the same data type
mat <- matrix(1:6, nrow = 2, ncol = 3)
mat

# Indexing: accessing elements [row, column]
mat[2, 3]   # 10

# --------------------------------------------------------------
# Reading and Writing Data
# --------------------------------------------------------------

# To read and write data, make sure the file path is correct

# Reading a CSV file
# data <- read.csv("path_to_your_file.csv")

# Writing data to a CSV file
write.csv(vec, file = "vector.csv")

# --------------------------------------------------------------
# Functions
# --------------------------------------------------------------

# Define your own function
add <- function(x, y) {
  result <- x + y
  return(result)
}

add(3, 4)

# --------------------------------------------------------------
# Plotting Basics
# --------------------------------------------------------------

# Basic scatter plot
x <- 1:10
y <- x^2
plot(x, y, main = "Basic Scatter Plot", xlab = "X-axis", ylab = "Y-axis")

# --------------------------------------------------------------
# Installing and Loading Packages
# --------------------------------------------------------------

# Installing a package (run only once)
# install.packages("ggplot2")

# Loading a package (every time you start a session)
library(ggplot2)

# Example ggplot2 plot
data <- data.frame(x = rnorm(100), y = rnorm(100))
ggplot(data, aes(x = x, y = y)) + geom_point() + labs(title = "Scatter Plot")

