
library(data.table)
library(tidyverse)
library(lubridate)
library(sf)
library(lwgeom)
library(stringr)
library(pbapply)
albersNA = aea.proj <- "+proj=aea +lat_1=29.5 +lat_2=45.5 +lat_0=37.5 +lon_0=-110 +x_0=0 +y_0=0 +ellps=GRS80 +datum=NAD83 +units=m"

ranger_url ="https://data.fs.usda.gov/geodata/edw/edw_resources/shp/S_USA.RangerDistrict.zip"
td = tempdir()
tf = tempfile(tmpdir=td, fileext=".zip")
download.file(ranger_url, tf)
fname = unzip(tf, list=TRUE)
unzip(tf, files=fname$Name, exdir=td, overwrite=TRUE)
fpath = file.path(td, grep('shp$',fname$Name,value=T))
ranger_districts <- st_read(fpath)
ranger_districts <- st_transform(ranger_districts,crs = st_crs(albersNA))
ranger_districts  <- st_make_valid(ranger_districts)

ranger_districts$DISTRICTNA = as.character(ranger_districts$DISTRICTNA)
ranger_districts$RANGERDIST = as.character(ranger_districts$RANGERDIST)
ranger_districts$FORESTNAME = as.character(ranger_districts$FORESTNAME)
ranger_districts$DISTRICTOR = as.character(ranger_districts$DISTRICTOR)
ranger_districts$DISTRICT_ID  = ranger_districts$DISTRICTOR
#ranger_districts$DISTRICT_ID <- str_extract(ranger_districts$DISTRICTOR,'[0-9]{6}$')
ranger_districts$FOREST_ID = str_extract(ranger_districts$DISTRICT_ID,'^[0-9]{4}')


library(noncompliance)
tdt = expand.grid.DT(sort(unique(ranger_districts$DISTRICT_ID)),2000:2018)
setnames(tdt,c('DISTRICT_ID',"FISCAL_YEAR"))
temp_dt = tdt

#### ranger district x county overlap values
county_over = fread('input/gis_overlap_props/rangerdistrict_county_overlap_props.csv')
#setnames(county_over,"DISTRICTOR","DISTRICT_ID")
county_over$DISTRICT_ID = formatC(county_over$DISTRICT_ID,width=6,flag=0)
county_over$CFIPS = formatC(county_over$CFIPS,width=5,flag=0)
county_over$Prop_Overlap = round(county_over$Prop_Overlap,3)
county_over <- county_over[county_over$Prop_Overlap>0,]

####### county business pattern overlay
cbp_list = lapply(list.files('input/cpb_data/','with_ann',full.names = T),function(x) {
  tt=fread(x,skip = 1)
  names(tt) = gsub('[0-9]{4}\\s','',names(tt));names(tt) = gsub("Paid employees for pay period including March 12 (number)","Number of employees",names(tt),fixed=T)
  tt})
cbp_dt = rbindlist(cbp_list,fill = T)
cbp_dt = cbp_dt[,.(Id2,`NAICS code`,Year,`Number of employees`)]
setnames(cbp_dt,c('Id2',"NAICS code","Number of employees"),c('CFIPS','NAICS',"Number_employees"))
cbp_dt$CFIPS = formatC(cbp_dt$CFIPS,width=5,flag=0)
cbp_dt = dcast(cbp_dt,CFIPS + Year ~ NAICS,value.var = 'Number_employees')
cbp_dt = cbp_dt[!grepl('000$',cbp_dt$CFIPS),]
setnames(cbp_dt,c('113',"114","21","71","0"),c('forestry_logging','fishing_hunting',"mining","recreation_entertainment","all_employees"))
simulate_blurred_response = function(x){
  round(ifelse(is.na(x),NA,ifelse(!is.na(as.numeric(x)),as.numeric(x),ifelse(x=='a',runif(length(x),1,19),ifelse(x=='b',runif(length(x),20,99),
                                                                                                                 ifelse(x=='c',runif(length(x),100,249),ifelse(x=='e',runif(length(x),250,499),ifelse(x=='f',runif(length(x),500,999),
                                                                                                                                                                                                      ifelse(x=='g',runif(length(x),1000,2499),ifelse(x=='h',runif(length(x),2500,4999),NA))))))))))}
vnames = c('all_employees','mining','recreation_entertainment',
           'forestry_logging','fishing_hunting')
cbp_dt = cbp_dt[,(vnames):=lapply(.SD,simulate_blurred_response),.SDcols=vnames]

cbp_dt$Prop_Forestry_Employ = cbp_dt$forestry_logging/cbp_dt$all_employees
cbp_dt$Prop_Mining_Employ = cbp_dt$mining/cbp_dt$all_employees
cbp_dt$Prop_Recreation =  cbp_dt$recreation_entertainment/cbp_dt$all_employees
cbp_dt$Prop_HuntingFishing = cbp_dt$fishing_hunting/cbp_dt$all_employees
setkey(county_over,CFIPS)
setkey(cbp_dt,CFIPS)

cbp_dt_over = merge(county_over,cbp_dt,all.x=T)
cbp_dt_over = cbp_dt_over[!is.na(Year),]
cbp_props = cbp_dt_over[,lapply(.SD,weighted.mean,w=Prop_Overlap,na.rm=T), by=.(DISTRICT_ID,Year),.SDcols = grep('Prop_[^O]',names(cbp_dt_over),value=T)]
setnames(cbp_props,'Year','FISCAL_YEAR')
setkey(cbp_props,DISTRICT_ID,FISCAL_YEAR)
setkey(temp_dt,DISTRICT_ID,FISCAL_YEAR)


temp_dt = merge(temp_dt,cbp_props,all=T)
###


###### add county voting pattern #######
county_voting = readRDS('input/politics/countyVoteShare_5-2019.rds')
county_voting = as.data.table(county_voting)
county_voting = county_voting[,.(percentD_H,year,GEOID)]
setnames(county_voting,c('percentD_H','year','GEOID'),
         c('percentD_H','FISCAL_YEAR','CFIPS'))
setkey(county_over,CFIPS)
setkey(county_voting,CFIPS)
county_voting_over = merge(county_voting,county_over)

district_voting_weighted = county_voting_over[,lapply(.SD,weighted.mean,w=Prop_Overlap,na.rm=T), by=.(DISTRICT_ID,FISCAL_YEAR),.SDcols = 'percentD_H']
setkey(district_voting_weighted,DISTRICT_ID,FISCAL_YEAR)
setkey(temp_dt,DISTRICT_ID,FISCAL_YEAR)
temp_dt = merge(temp_dt,district_voting_weighted,all=T)

county_covs = fread('input/county_covariates_1994-2017.csv')
county_covs$CFIPS = formatC(county_covs$COUNTY_FIPS,width=5,flag = 0)
county_covs$Year = as.character(county_covs$Year)
setkey(county_covs,CFIPS)
setkey(county_over,CFIPS)
county_covs = county_covs[county_over,]
district_weighted_covs = county_covs[,lapply(.SD,weighted.mean,w=Prop_Overlap), by=.(DISTRICT_ID,Year),.SDcols = 
                                       c("Unemp_Rate","Prop_SNAP_recipients","Population")]
setnames(district_weighted_covs,'Year','FISCAL_YEAR')
district_weighted_covs$FISCAL_YEAR = as.character(district_weighted_covs$FISCAL_YEAR)
temp_dt$FISCAL_YEAR <- as.character(temp_dt$FISCAL_YEAR)
setkey(district_weighted_covs,DISTRICT_ID,FISCAL_YEAR)
setkey(temp_dt,DISTRICT_ID,FISCAL_YEAR)
temp_dt = merge(temp_dt,district_weighted_covs,all=T)

###### add house representative variables
house = readRDS('input/politics/houseAtts_5-2019.RDS')
house = data.table(house)
setnames(house,'year','FISCAL_YEAR')
house$Congressional_District_ID <- formatC(house$Congressional_District_ID,width=4,flag = 0)
setkey(house,FISCAL_YEAR,Congressional_District_ID)

house_overs = fread('input/gis_overlap_props/rangerdistrict_congressdistrict_overlap_props.csv')
house_overs$DISTRICT_ID = formatC(house_overs$DISTRICT_ID,width=6,flag = 0)
house_overs$Congressional_District_ID <- formatC(gsub('00$','01',house_overs$Congressional_District_ID),width=4,flag=0)
setnames(house_overs,'Year','FISCAL_YEAR')
setkey(house_overs,FISCAL_YEAR,Congressional_District_ID)
house_dt = house_overs[house,]
house_dt$Prop_Overlap = round(house_dt$Prop_Overlap,2)
house_dt = house_dt[house_dt$Prop_Overlap>0,]
district_house_values = house_dt[,lapply(.SD,weighted.mean,w=Prop_Overlap), by=.(DISTRICT_ID,FISCAL_YEAR),.SDcols = c("LCV_annual","LCV_lifetime","democrat","nominate_dim1",'nominate_dim2')]
district_house_values$FISCAL_YEAR = as.character(district_house_values$FISCAL_YEAR)
setkey(district_house_values,'DISTRICT_ID','FISCAL_YEAR')
setkey(temp_dt,'DISTRICT_ID','FISCAL_YEAR')
temp_dt = merge(temp_dt,district_house_values,all=T)


#########
temp_dt$index_in_rangershp = match(temp_dt$DISTRICT_ID,ranger_districts$DISTRICT_ID)
temp_dt$GIS_Area = st_area(ranger_districts)[temp_dt$index_in_rangershp]

#### wildfire burn overlay
#wildfire_burn_url = 'https://wildfire.cr.usgs.gov/firehistory/data/wf_usfs_1980_2016.zip'
wildfire_burn_url = 'https://data.fs.usda.gov/geodata/edw/edw_resources/shp/S_USA.MTBS_BURN_AREA_BOUNDARY.zip'
tf = tempfile(tmpdir=td, fileext=".zip")
download.file(wildfire_burn_url, tf)
fname = unzip(tf, list=TRUE)
unzip(tf, files=fname$Name, exdir=td, overwrite=TRUE)
fpath = file.path(td, grep('shp$',fname$Name,value=T))
wildfire_burn <- st_read(fpath)
wildfire_burn <- st_transform(wildfire_burn,crs = st_crs(albersNA))
wildfire_burn  <- st_make_valid(wildfire_burn)
setnames(wildfire_burn,'YEAR','FISCAL_YEAR')
temp_dt$FISCAL_YEAR = as.numeric(temp_dt$FISCAL_YEAR)

wildfire_index = sapply(seq_along(temp_dt$FISCAL_YEAR),function(x) which(wildfire_burn$FISCAL_YEAR<temp_dt$FISCAL_YEAR[x]&wildfire_burn$FISCAL_YEAR>(temp_dt$FISCAL_YEAR[x]-6)))
wildfire_inters = st_intersects(ranger_districts,wildfire_burn)
wildfire_intersections = mapply(function(x,y) intersect(x,y),x = wildfire_inters[temp_dt$index_in_rangershp],wildfire_index)
total_burn_area_past5yrs = pbsapply(1:nrow(temp_dt),function(i){if(length(wildfire_intersections[[i]])==0){0}
  else{sum(st_area(st_intersection(ranger_districts[temp_dt$index_in_rangershp[i],],wildfire_burn[wildfire_intersections[[i]],])))}},cl = 10)
temp_dt$Burned_Area_Past5yrs = total_burn_area_past5yrs
temp_dt$Burned_Prop_Past5yrs = temp_dt$Burned_Area_Past5yrs/temp_dt$GIS_Area


#### limited use overlay
limit_use_url = 'https://data.fs.usda.gov/geodata/edw/edw_resources/shp/S_USA.OthNatlDesgAreaStatus.zip'
tf = tempfile(tmpdir=td, fileext=".zip")
download.file(limit_use_url, tf)
fname = unzip(tf, list=TRUE)
unzip(tf, files=fname$Name, exdir=td, overwrite=TRUE)
fpath = file.path(td, grep('shp$',fname$Name,value=T))
limit_use <- st_read(fpath)
limit_use <- st_transform(limit_use,crs = st_crs(albersNA))
limit_use  <- st_make_valid(limit_use)
limit_use$FISCAL_YEAR = year(limit_use$ACTIONDATE) + (month(limit_use$ACTIONDATE)>=10 + 0)

limit_use_index = sapply(seq_along(temp_dt$FISCAL_YEAR),function(x) which(limit_use$FISCAL_YEAR<temp_dt$FISCAL_YEAR[x]))
limit_use_inters = st_intersects(ranger_districts,limit_use)
limit_use_intersections = mapply(function(x,y) intersect(x,y),x = limit_use_inters[temp_dt$index_in_rangershp],limit_use_index)
total_limited_use_area = pbsapply(1:nrow(temp_dt),function(i){if(length(limit_use_intersections[[i]])==0){0}
  else{sum(st_area(st_intersection(ranger_districts[temp_dt$index_in_rangershp[i],],st_union(limit_use[limit_use_intersections[[i]],]))))}},cl = 10)
temp_dt$Limited_Use_Area = total_limited_use_area
temp_dt$Limited_Use_Prop = temp_dt$Limited_Use_Area/temp_dt$GIS_Area

###### wilderness area overlay
wilderness_area_url = 'https://data.fs.usda.gov/geodata/edw/edw_resources/shp/S_USA.Wilderness.zip'
tf = tempfile(tmpdir=td, fileext=".zip")
download.file(wilderness_area_url, tf)
fname = unzip(tf, list=TRUE)
unzip(tf, files=fname$Name, exdir=td, overwrite=TRUE)
fpath = file.path(td, grep('shp$',fname$Name,value=T))
wilderness_area <- st_read(fpath)
wilderness_area <- st_transform(wilderness_area,crs = st_crs(albersNA))
wilderness_area  <- st_make_valid(wilderness_area)

desig_years_url = 'https://www.wilderness.net/GIS/Wilderness_Areas.zip'
tf = tempfile(tmpdir=td, fileext=".zip")
download.file(desig_years_url, tf)
fname = unzip(tf, list=TRUE)
unzip(tf, files=fname$Name, exdir=td, overwrite=TRUE)
fpath = file.path(td, grep('shp$',fname$Name,value=T))
desig_years <- st_read(fpath)
wilderness_area$DESIG_YEAR = desig_years$YearDesign[match(formatC(wilderness_area$WID,width=3,flag=0),formatC(desig_years$WID,width=3,flag=0))]
wilderness_area$DESIG_YEAR[wilderness_area$WILDERNESS=='10460010343\r\n'] <- 1994
over_wilderness = st_intersects(ranger_districts,wilderness_area)

wilderness_index = sapply(seq_along(temp_dt$FISCAL_YEAR),function(x) which(wilderness_area$DESIG_YEAR<temp_dt$FISCAL_YEAR[x]))
wilderness_inters = st_intersects(ranger_districts,wilderness_area)
wilderness_intersections = mapply(function(x,y) {if(length(x)==0){NA}else{intersect(x,y)}},x = wilderness_inters[temp_dt$index_in_rangershp],y = wilderness_index)
total_wilderness_area = pbsapply(1:nrow(temp_dt),function(i){if(length(wilderness_intersections[[i]])==0){0}
  else{sum(st_area(st_intersection(ranger_districts[temp_dt$index_in_rangershp[i],],st_union(wilderness_area[wilderness_intersections[[i]],]))))}},cl = 10)
temp_dt$Wilderness_Area = total_wilderness_area
temp_dt$Wilderness_Prop = temp_dt$Wilderness_Area/temp_dt$GIS_Area

#saveRDS(temp_dt,'scratch/data_file.RDS')


##### count listed species over project area
habitat_url = 'https://ecos.fws.gov/docs/crithab/crithab_all/crithab_all_layers.zip'
td = tempdir()
tf = tempfile(tmpdir=td, fileext=".zip")
download.file(habitat_url, tf)
fname = unzip(tf, list=TRUE)
unzip(tf, files=fname$Name, exdir=td, overwrite=TRUE)
fpath = file.path(td, grep('shp$',fname$Name,value=T))

hab_poly <- st_read(grep('POLY',fpath,value=T))
hab_poly <- st_transform(hab_poly,crs = st_crs(albersNA))
hab_poly  <- st_make_valid(hab_poly)
hab_poly$FR_Date = ymd(as.character(hab_poly$pubdate))
hab_poly$FISCAL_YEAR = year(hab_poly$FR_Date) + (month(hab_poly$FR_Date)>=10 + 0)
hab_poly_intersects = st_intersects(ranger_districts,hab_poly)

hab_poly_count = pbsapply(1:nrow(temp_dt),function(i){
  if(is.na(temp_dt$DISTRICT_ID[[i]])){NA}
  else if(length(hab_poly_intersects[[temp_dt$index_in_rangershp[[i]]]])==0){0}
  else{hab_poly[hab_poly_intersects[[temp_dt$index_in_rangershp[i]]],]%>%filter(FISCAL_YEAR<temp_dt$FISCAL_YEAR[i]) %>%
      filter(!duplicated(sciname)) %>% nrow(.)}},cl = 8)

hab_line <- st_read(grep('LINE',fpath,value=T))
hab_line <- st_transform(hab_line,crs = st_crs(albersNA))
hab_line  <- st_make_valid(hab_line)
hab_line$FR_Date = ymd(as.character(hab_line$pubdate))
hab_line$FISCAL_YEAR = year(hab_line$FR_Date) + (month(hab_line$FR_Date)>=10 + 0)
hab_line_intersects = st_intersects(ranger_districts,hab_line)
hab_line_count = pbsapply(1:nrow(temp_dt),function(i){
  if(is.na(temp_dt$DISTRICT_ID[[i]])){NA}
  else if(length(hab_line_intersects[[temp_dt$index_in_rangershp[[i]]]])==0){0}
  else{hab_line[hab_line_intersects[[temp_dt$index_in_rangershp[i]]],]%>%filter(FISCAL_YEAR<temp_dt$FISCAL_YEAR[i]) %>%
      filter(!duplicated(sciname)) %>% nrow(.)}},cl = 8)
temp_dt$Count_Species_CriticalHabitat = hab_poly_count + hab_line_count


####### overlay subsurface mineral rights on ranger district
mineral_rights_url = 'https://data.fs.usda.gov/geodata/edw/edw_resources/shp/S_USA.MINERALRIGHT.zip'
td = tempdir()
tf = tempfile(tmpdir=td, fileext=".zip")
download.file(mineral_rights_url, tf)
fname = unzip(tf, list=TRUE)
unzip(tf, files=fname$Name, exdir=td, overwrite=TRUE)
fpath = file.path(td, grep('shp$',fname$Name,value=T))
mineral_rights <- st_read(fpath)
mineral_rights <- st_transform(mineral_rights,crs = st_crs(albersNA))
mineral_rights  <- st_make_valid(mineral_rights)
mineral_rights$FISCAL_YEAR = mineral_rights$ACTIONFISC
over_minerals = st_intersects(ranger_districts,mineral_rights)
mineral_index = sapply(seq_along(temp_dt$FISCAL_YEAR),function(x) which(mineral_rights$FISCAL_YEAR<temp_dt$FISCAL_YEAR[x]))
mineral_inters = st_intersects(ranger_districts,mineral_rights)
mineral_intersections = mapply(function(x,y) {if(length(x)==0){NA}else{intersect(x,y)}},x = mineral_inters[temp_dt$index_in_rangershp],y = mineral_index)
total_mineral_rights = pbsapply(1:nrow(temp_dt),function(i){if(length(mineral_intersections[[i]])==0){0}
  else{sum(st_area(st_intersection(ranger_districts[temp_dt$index_in_rangershp[i],],st_union(mineral_rights[mineral_intersections[[i]],]))))}},cl = 10)
temp_dt$Mineral_Rights_Area = total_mineral_rights
temp_dt$Mineral_Rights_Prop = temp_dt$Mineral_Rights_Area/temp_dt$GIS_Area

# 
# ##### overlay rangeland on ranger districts
# allotments_url = 'https://data.fs.usda.gov/geodata/edw/edw_resources/shp/S_USA.Allotment.zip'
# # create a temporary directory
# td = tempdir()
# # create the placeholder file
# tf = tempfile(tmpdir=td, fileext=".zip")
# # download into the placeholder file
# download.file(allotments_url, tf)
# # get the name of the first file in the zip archive
# fname = unzip(tf, list=TRUE)
# # unzip the file to the temporary directory
# unzip(tf, files=fname$Name, exdir=td, overwrite=TRUE)
# # fpath is the full path to the extracted file
# fpath = file.path(td, grep('shp$',fname$Name,value=T))
# allotments <- st_read(fpath)
# allotments <- st_transform(allotments,crs = st_crs(albersNA))
# allotments  <- st_make_valid(allotments)
# allotments$FISCAL_YEAR = allotments$NEPA_DEC_A
# over_allotments = st_intersects(ranger_districts,allotments)
# allotments_index = sapply(seq_along(temp_dt$FISCAL_YEAR),function(x) which(allotments$FISCAL_YEAR<temp_dt$FISCAL_YEAR[x]))
# allotments_inters = st_intersects(ranger_districts,allotments)
# allotments_intersections = mapply(function(x,y) {if(length(x)==0){NA}else{intersect(x,y)}},x = allotments_inters[temp_dt$index_in_rangershp],y = allotments_index)
# 
# 
# 
# total_allotments = pbsapply(1:nrow(temp_dt),function(i){
#   if(length(allotments_intersections)==0){0}
#   if(i>1 & identical(allotments_intersections[i],allotments_intersections[i-1])){NA}
# else{sum(st_area(st_intersection(ranger_districts[temp_dt$index_in_rangershp[i],],
#                               allotments[allotments_intersections[[i]],]))) / temp_dt$GIS_Area[i]
# }},cl = 10)
# 
# total_allotments = zoo::na.locf(total_allotments)
# temp_dt$Allotments_Area = total_allotments
# temp_dt$Allotments_Prop = temp_dt$Allotments_Area/temp_dt$GIS_Area
# temp_dt$Allotments_Prop[temp_dt$Allotments_Prop>1]<- 1

####### overlay subsurface mineral rights on ranger district
eco_sections_url = 'https://data.fs.usda.gov/geodata/edw/edw_resources/shp/S_USA.EcomapSections.zip'
td = tempdir()
tf = tempfile(tmpdir=td, fileext=".zip")
download.file(eco_sections_url, tf)
fname = unzip(tf, list=TRUE)
unzip(tf, files=fname$Name, exdir=td, overwrite=TRUE)
fpath = file.path(td, grep('shp$',fname$Name,value=T))
eco_sections <- st_read(fpath)
eco_sections <- st_transform(eco_sections,crs = st_crs(albersNA))
eco_sections  <- st_make_valid(eco_sections)
over_eco_sections = st_intersects(ranger_districts,eco_sections)
temp_dt$Num_Eco_Sections = sapply(over_eco_sections,length)[temp_dt$index_in_rangershp]

saveRDS(temp_dt,'input/prepped/ranger_district_covariates.RDS')

