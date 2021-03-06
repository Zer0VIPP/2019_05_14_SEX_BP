library(reshape2)
library(data.table) # v1.9.5+
library(matrixStats)
library(magrittr)
library(testthat) # install.packages("testthat")
library(readr)
library(ggplot2)
library(tidyr)
library(purrr)
library(dplyr)
library(segmented) # install.packages("segmented")
library(nlme)
library(haven)
library(boot)

comb_dat <- readRDS("data/comb_dat.rds") %>% filter(SEX==2)
comb_dat %<>% mutate(AGE = round(AGE),
                     id = as.numeric(id))
head(comb_dat)
# Filter out those who were under 18 at baseline --------------------------

u1850 <-
  comb_dat %>%
  filter(visit == 1) %>%
  distinct(AGE, id) %>%
  filter(AGE < 18)

baselinehtn <-
  comb_dat %>%
  filter(visit == 1) %>% 
  distinct(HRX, SBP, DBP, AGE, id) %>%
  filter((HRX == 1 | SBP > 140 | DBP > 90) & AGE > 45)

num_visit <-
  comb_dat %>%
  group_by(id) %>%
  dplyr::summarise(n = n()) %>%
  filter(n < 4)

comb_dat %<>%
  anti_join(u1850, by = 'id')%>%
  anti_join(num_visit, by = 'id') %>%
  anti_join(baselinehtn, by = 'id') 


rm(u1850, baselinehtn, num_visit)

# Filter out unmeasured exams and exams those never diagnosed with hptn --------

onset <- comb_dat %>% 
  mutate(onsetage = ifelse(SBP >= 140 | DBP >=90 | HRX == 1, AGE, NA)) %>%
  setDT() %>%
  dcast(id ~ visit, value.var = c("onsetage")) 

onset$onsetage <- apply(dplyr::select(onset, -id), 1, FUN = min, na.rm = T)

onset %<>% mutate(onsetage = ifelse(onsetage == Inf, NA, onsetage))
onset$onsetage %>% hist()

onset_NA <- onset %>% filter(is.na(onsetage))
onset_age <- onset %>% filter(!is.na(onsetage)) 

# Custom Age Buckets ------------------------------------------------------

# Teemu requested age_categories
age_breaks <-
  list(
    data_frame(
      start = c(seq(15.01, 85.01, 10)),
      end   = start + 10,
      category = paste(start, end, sep = '-')
    ),
    data_frame(
      start = c(seq(15.01, 75.01, 15)),
      end   = start + 15,
      category = paste(start, end, sep = '-')
    ),
    data_frame(
      start = c(15,45,55,65),
      end   = c(45,55,65,95),
      category = paste(start-0.01, end-0.01, sep = '-')
    )
  )


multi_ifelse <- function(x, breaks) {
  level <- 1
  output <- rep(0, length(x))
  
  if ('tbl_df' %in% class(breaks)) {
    breaks %<>% as.data.frame()
  }
  
  # Later categroy takes the intersections
  for (i in seq_len(nrow(breaks))) {
    output <-
      ifelse(between(x, breaks[i, 'start'], breaks[i, 'end']), breaks$category[level], output)
    level <- level + 1
  }
  
  output <-
    as.factor(output)
  
  return(output)
}


# AGE CATEGORIES

age_categories <-
  onset_age %>%
  distinct(id, onsetage) %>%
  mutate(
    category_quintile = cut(onsetage, breaks = quantile(onsetage, probs = seq(0,1,0.2))),
    category_1       = multi_ifelse(onsetage, age_breaks[[1]]),
    category_2       = multi_ifelse(onsetage, age_breaks[[2]]),
    category_3       = multi_ifelse(onsetage, age_breaks[[3]])
  )

sum(age_categories$category_3=="0")

na_id <-
  onset_NA %>%
  distinct(id)

age_categories %<>% 
  add_row(id = na_id[[1]]) %>%
  mutate_at(vars(category_quintile:category_3), funs(ifelse(id %in% na_id[[1]], 'NO_HTN', .))) %>%
  mutate_at(vars(category_quintile:category_3), as.factor)

onset_age %<>% bind_rows(onset_NA)

# Fix Mislabeled Category_Quintile -------------------------------------------------------
# The automatically generated breaks sometimes excludes respondents below the minimum age cutoff.
# We assign missing people to the lowest category.

age_categories %<>%
  mutate(category_quintile = ifelse(
    is.na(category_quintile),
    levels(category_quintile)[1],
    as.character(category_quintile)
  )) %>%
  mutate(category_quintile = as.factor(category_quintile))

stopifnot(!any(is.na(age_categories$category_quintile)))

# Group Sizes -------------------------------------------------------------
age_category_names <- grep('^cat', names(age_categories), value = T)

age_category_sizes <- map(age_category_names, function(category) {
  age_categories %>%
    group_by_(category) %>%
    dplyr::summarise(n =  n()) %>%
    set_names(c('category', 'n'))
}) %>%
  set_names(age_category_names) %>%
  bind_rows(.id = 'category_type')


# Format Data For Modeling -------------------------------------------------------

comb_dat %<>%
  left_join(age_categories, by = "id") %>% # diag_age
  filter(onsetage < 80 | is.na(onsetage))

head(comb_dat)

saveRDS(comb_dat, "comb_dat_f.rds")


line1 <- comb_dat %>% 
  filter(category_3 == 1) %>% 
  filter(AGE <= quantile(AGE, 0.995) & AGE >= quantile(AGE, 0.005))
line2 <- comb_dat %>% 
  filter(category_3 == 2) %>% 
  filter(AGE <= quantile(AGE, 0.995) & AGE >= quantile(AGE, 0.005))
line3 <- comb_dat %>% 
  filter(category_3 == 3) %>% 
  filter(AGE <= quantile(AGE, 0.995) & AGE >= quantile(AGE, 0.005))
line4 <- comb_dat %>% 
  filter(category_3 == 4) %>% 
  filter(AGE <= quantile(AGE, 0.995) & AGE >= quantile(AGE, 0.005))
line5 <- comb_dat %>% 
  filter(category_3 == "NO_HTN") %>% 
  filter(AGE <= quantile(AGE, 0.995) & AGE >= quantile(AGE, 0.005))

plot_x_min <- max(min(line2$AGE), min(line3$AGE), min(line4$AGE), min(line5$AGE))
plot_x_max <- max(comb_dat$AGE)

comb_dat$category_3 %>% as.factor() %>% summary()
# Model Function ----------------------------------------------------------

ctrl <- lmeControl(opt = 'optim')

seg_model <- function(d) {
  segmented.lme(
    lme(
      SBP ~ AGE,
      control = ctrl,
      data = d,
      random =  list(id = ~ 1)
    ),
    Z = AGE,
    random = list(id = pdDiag(~ 1)))
  }

# Segmented models --------------------------------------------------------

changeline <- function(x) {
              minx <- min(range(x$data$AGE))
              maxx <- max(range(x$data$AGE))
              
              plot_min <- minx + 0.05*(maxx - minx)
              plot_max <- maxx - 0.05*(maxx - minx)
              
              x <- x$tTable
              rnames <- rownames(x)
              
              estimates = x[, 1]
              int = estimates[rnames == '(Intercept)']
              slope = estimates[rnames == 'AGE']
              deltaSlope = estimates[rnames == 'U']
              changepoint = estimates[rnames == 'G0']
              
              newX1 = seq(plot_min, changepoint, length.out = 2)
              newX2 = seq(changepoint, plot_max, length.out = 2)
              
              
              newY1 = int + newX1 * slope
              newY2 = max(newY1) + (newX2 - changepoint) * (slope + deltaSlope)
              
              return(data_frame(
                x = unique(c(newX1, newX2)),
                y = unique(c(newY1, newY2))
              ))}


slope_ci <- function(seglm) {
  #asymptotic 95%CI for the left and right slopes
  b <- fixef(seglm[[2]])[c("AGE", "U")] #model estimates, left slope and diffSlope
  A <- matrix(c(1,1,0,1),2,byrow=FALSE)
  
  new<- drop(A%*%b) #left slope and right slopes
  V<-vcov(seglm[[1]])[c("AGE", "U"), c("AGE", "U")]
  V.new<- A %*% V %*% t(A)
  se.new<-sqrt(diag(V.new))

  out <- 
    cbind(low=new -1.96*se.new, up=new +1.96*se.new) %>%
    as.data.frame(row.names = c('before_breakpoint', 'after_breakpoint')) %>%
    tibble::rownames_to_column(var = "slope")
  
  out %>%
    bind_cols(data_frame(est = new, se = se.new))
}



d <- line1 %>% filter(AGE < 45) -> d1
lmefit1 <- seg_model(d)$lme.fit %>% summary()
fitci1 <- slope_ci(seg_model(d))
cl1 <- changeline(lmefit1)

d <- line2 %>% filter(AGE < 55) -> d2
lmefit2 <- seg_model(d)$lme.fit %>% summary()
fitci2 <- slope_ci(seg_model(d))
cl2 <- changeline(lmefit2) 

d <- line3 %>% filter(AGE < 65) -> d3
lmefit3 <- seg_model(d)$lme.fit %>% summary()
fitci3 <- slope_ci(seg_model(d))
cl3 <- changeline(lmefit3) 

d <- line4 %>% filter(AGE < 80) -> d4
lmefit4 <- seg_model(d)$lme.fit %>% summary()
fitci4 <- slope_ci(seg_model(d))
cl4 <- changeline(lmefit4) 

line5 -> d5
cl5 <- data.frame(x = c(50),y = c(130))



library(splines)
library(lspline) # install.packages("lspline")

gg_color_hue <- function(n) {
  hues = seq(15, 375, length = n + 1)
  hcl(h = hues, l = 65, c = 100)[1:n]
}
n = 8
cols = gg_color_hue(n)

ggplot() +
  coord_cartesian(ylim = c(105, 145), xlim = c(20, 85)) +
  geom_smooth(aes(x = AGE, y = SBP, color = "40s", fill = "40s"), linetype = "dotted", method = "loess", data = d1, show.legend = F) +
  geom_smooth(aes(x = AGE, y = SBP, color = "50s", fill = "50s"), linetype = "dotted", method = "loess", data = d2, show.legend = F) +
  geom_smooth(aes(x = AGE, y = SBP, color = "60s", fill = "60s"), linetype = "dotted", method = "loess", data = d3, show.legend = F) +
  geom_smooth(aes(x = AGE, y = SBP, color = "70s", fill = "70s"), linetype = "dotted", method = "loess", data = d4, show.legend = F) +
  geom_smooth(aes(x = AGE, y = SBP, color = "never", fill = "never"), linetype = "dotted", method = "loess", data = d5, show.legend = F) +
  geom_line(aes(x = x, y = y, color = "40s"), data = cl1) +
  geom_line(aes(x = x, y = y, color = "50s"), data = cl2) +
  geom_line(aes(x = x, y = y, color = "60s"), data = cl3) +
  geom_line(aes(x = x, y = y, color = "70s"), data = cl4) +
  geom_line(aes(x = x, y = y, color = "never"), data = cl5, alpha = 0) +
  scale_color_manual(name = "Age at Hypertension Onset",
                     values = c("40s" = "blue4", "50s" = cols[2], "60s" = cols[6], "70s" = cols[1], "never" = cols[4]),
                     labels = c("40s" = "~ 44", "50s" = "45-54", "60s" = "55-64", "70s" = "65-79", "never" = "No onset")) +
  scale_fill_manual(name = "Age at Hypertension Onset",
                     values = c("40s" = "blue4", "50s" = cols[2], "60s" = cols[6], "70s" = cols[1], "never" = cols[4]),
                     labels = c("40s" = "~ 44", "50s" = "45-54", "60s" = "55-64", "70s" = "65-79", "never" = "No onset")) +
  scale_y_continuous(name = "SBP, mm Hg") + 
  scale_x_continuous(breaks = seq(from = 20, to = 90, by = 10), expand = c(0,0)) + 
  ggtitle("Women") +
  theme_bw() +
  theme(axis.title = element_text(color = "#434443",size =15,face="bold"),
        axis.text = element_text(color = "#434443",size =12,face="bold"),
        title = element_text(color = "#434443",size =16,face="bold"),
        legend.position = "bottom")


