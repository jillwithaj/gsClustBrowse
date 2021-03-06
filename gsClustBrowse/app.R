#
# This is a Shiny web application. You can run the application by clicking
# the 'Run App' button above.
#
# Find out more about building applications with Shiny here:
#
#    http://shiny.rstudio.com/
#

library(shiny)
library(DT)
library(tidyverse)
library(dbplyr)
library(DBI)
library(odbc)
library(config)

# get database configuration info from the config.yml file
dsn <- get("gsint")
# connect to the database
con <- dbConnect(odbc::odbc(),driver = dsn$driver, database = dsn$database , timeout = 10)

pops <- c("East Polynesian","West Polynesian", "European", "Asian")
batch <- 1:13

# define genotype colour scale
gt_colours <- scale_color_manual( values=c("NC" = "grey", "BB" = "green", "AB" = "blue", "AA" ="red"))
sex_colours <- scale_color_manual(values = c("Female" = "orange", "Male" = "purple", "Missing" = "lightgrey", "Unknown" = "lightgrey"))

onStop(function() {
    dbDisconnect(con)
})

# Define UI for application that draws a histogram
ui <- fluidPage(

    # Application title
    titlePanel("Browse Intensities"),
    sidebarPanel(
        h3("Filter Markers"),
        radioButtons("marker_filter", label = "Select by marker or position", choices = list(Position = "position", Marker = "marker")  ),
        textInput("probe_id", label = "Probe ID",value = NULL ,placeholder = "Enter a valid probe id (not currently implementec" ),
        numericInput("markerinfo_chr", value = 1, min = 1, label = "Chr", width = 150),
        numericInput("markerinfo_start", value = 1, min = 1, label = "Start"),
        numericInput("markerinfo_end", value = 1e6, min = 1, label = "End"),
        hr(),

        h3("Filter Data"),
        checkboxInput("inc_sample_callrate_lt_95", label = "Sample callrate < 98%", value = FALSE),
        checkboxInput("passed_gt_qc", label = "Samples that passed all QC", value = TRUE),
        radioButtons("sex_filter", label = "Sex", choices = list(All = "all", Male = "Male", Female = "Female")  ),
        selectInput("ancestry_filter", label = "Ancestry", choices = pops, selected = NULL, multiple = TRUE),
        selectInput("batch_filter", label = "QC Batch", choices = batch, selected = NULL, multiple = TRUE),

        h3("Plot Options"),
        radioButtons("coord_options", label = "Axes", choices = list(`Theta/R` = "theta_r", `X/Y` = "xy", `X/Y Raw` = "xy_raw")  ),
        radioButtons("facet_options", label = "Facet By", choices = list(None = "none", Ancestry = "ancestry", `Reported Sex` = "reported_sex", `Genetic Sex` = "genetic_sex")),
        radioButtons("colour_options", label = "Colour", choices = list(Gtype = "gtype", `Reported Sex` = "reported_sex", `Genetic Sex` = "genetic_sex", Ancestry = "ancestry")   )
        , width = 3),

    mainPanel(

        p("Click on a marker name"),
        fluidRow(
            dataTableOutput("markerinfo")),
        #dataTableOutput("testTable")
        fluidRow(textOutput("probename")),
        fluidRow(
            plotOutput("intensityPlot")
        )
    )
)


# Define server logic required to draw a histogram
server <- function(input, output) {
    # marker table
    markerinfo_tbl_pos <- reactive(tbl(con, "marker_info") %>%  select(chr, position, name) %>%
                                       filter(chr == input$markerinfo_chr, between(position, input$markerinfo_start, input$markerinfo_end)) %>%  select(name, chr, position) %>%
                                       arrange(position) #%>% as_tibble()
    )

    markerinfo_tbl_probe <- reactive(
        {mkr_tbl <- tbl(con, "marker_info") %>%  select(chr, position, name) %>% head(0) %>%  select(name, chr, position) %>% arrange(position)

        if(!is.null(input$probe_id)  & input$probe_id != ""){
            mkr_tbl <- tbl(con, "marker_info") %>%  select(chr, position, name) %>%
                filter(str_detect(name, input$probe_id)) %>%  select(name, chr, position) %>%
                arrange(name) #%>% as_tibble()
        }
        mkr_tbl
        }
    )
    # joined dataset
    combined_tbl <- tbl(con, "combined")
    #coord <- str_replace_all(input$coord, "-|:", " ") %>% str_split(., " ") %>% unlist() %>% set_names(., c("chr", "start", "end"))


    # return the marker table from the db so that markers can be browsed
    output$markerinfo <- renderDataTable(

            datatable({ markerinfo_table_pos_or_probe() %>%collect()}
                      , selection = list( target = "row", mode = "single"),
                      rownames = FALSE)
    )

    # filter the data to be supplied for plotting
    filtered_data <- reactive({
        marker_tbl <- markerinfo_table_pos_or_probe()

        # initially set marker to be *something*
        marker <- "exm101"
        if(!is.null(input$markerinfo_cell_clicked$col)){
            # if the marker table has been clicked, set the marker to be the marker name that was clicked
            if(colnames(marker_tbl)[input$markerinfo_cell_clicked$col +1 ] == "name"){
                marker <- input$markerinfo_cell_clicked$value
            }
        }

        # pull out the position information about the marker to use for filtering
        marker_detail <- marker_tbl %>% filter(name == marker) %>% collect()
        out_dat <- combined_tbl %>% filter(chr %in% marker_detail$chr, position %in% marker_detail$position) %>% collect()


        if(input$sex_filter != "all"){
            out_dat <- out_dat %>% filter(genetic_sex == input$sex_filter | reported_sex == input$sex_filter)
        }

        if(input$passed_gt_qc){
            out_dat <- out_dat %>% filter(passed_gt_qc == 1)
        }

        if(!input$inc_sample_callrate_lt_95){ # when TRUE remove samples with callrate < 95%
            out_dat <- out_dat %>% filter(callrate > 0.98)
        }
        out_dat %>% mutate(reported_sex = case_when(reported_sex == "Male" ~ "Male", reported_sex == "Female"~ "Female", is.na(reported_sex) | reported_sex == "" ~ "Missing"), genetic_sex = case_when(genetic_sex == "Male" ~ "Male", genetic_sex == "Female"~ "Female", (is.na(genetic_sex) | genetic_sex == "" | genetic_sex == "Unknown" | is.null(genetic_sex)) ~ "Unknown"))

    })



    # Plot of the intensities for the chosen marker
    output$intensityPlot <- renderPlot({
        dat <- filtered_data()#%>% mutate(gtype = forcats::as_factor(gtype) %>% forcats::lvls_expand(.,c("AA","AB","BB", "NC")))

        if(NROW(dat) == 0){
            return(NULL)
        }

        if(!is.null(input$batch_filter)){
            dat <- dat %>% filter(batchid %in% input$batch_filter)
        }
        selected_colour <- input$colour_options
        plot_title <- dat[["name"]][1]

        # coordinate plotting options
        p <- dat  %>% ggplot(aes(x = theta, y = r))
        if(input$coord_options == "xy"){
            p <-  dat  %>% ggplot(aes(x = x, y = y))
        } else if(input$coord_options == "xy_raw"){
            p <-  dat  %>% ggplot(aes(x = x_raw, y = y_raw))
        }

        # facetting
        if(input$facet_options == "none"){
            p <- p + facet_wrap(~ batchid)
        } else {
            facet <- paste0(input$facet_options, "~ batchid")
            p <- p + facet_grid( facet)
        }

        # colours
        if(input$colour_options == "gtype"){
            p <- p + geom_point(aes_string(colour = input$colour_options), alpha = 0.7) + gt_colours
        } else {
            p <-p + geom_point(aes_string(colour = input$colour_options), alpha = 0.7) + sex_colours
        }

        p <- p + ggtitle(plot_title) + theme_bw() + expand_limits(x = c(0,1), y = c(0,1))

        p
    })

    markerinfo_table_pos_or_probe <- reactive(
       { if(input$marker_filter == "position"){
            tab <- markerinfo_tbl_pos()
        }else{
            tab <- markerinfo_tbl_probe()
        }
        tab
       }
    )


    # watches for the marker table to be clicked and updates everything
    observeEvent(input$markerinfo_cell_clicked, {
        cell <- input$markerinfo_cell_clicked
        if(!is.null(cell$value)){
            if(colnames(markerinfo_table_pos_or_probe())[[cell$col +1 ]] == "name"){
                output$cell <- renderPrint(cell)
            }}
    })


}

# Run the application
shinyApp(ui = ui, server = server)
