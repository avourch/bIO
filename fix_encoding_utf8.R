fix_encoding_utf8 <- function(file_path = NULL,         # chemin du fichier à convertir
                                  output_dir = NULL,        # dossier de sortie
                                  encoding = NULL,          # encodage initial forcé (optionnel)
                                  force_encoding = NULL,    # encodage forcé si auto échoue
                                  bom = FALSE,              # ajouter BOM UTF-8 (utile pour Excel Windows)
                                  sep_out = ",",            # séparateur CSV de sortie
                                  verbose = TRUE,           # affiche messages détaillés
                                  ignore_col_warnings = FALSE, # ignorer warning colonnes incohérentes CSV
                                  log_file = NULL,          # chemin fichier log encodages testés
                                  csv_separators = c(",", ";", "\t", "|"), # séparateurs candidats pour CSV
                                  enc_sample_size = 100000, # taille échantillon pour détection encodage
                                  interactive_on_fail = TRUE) { # mode interactif si auto échoue
  
  # =========================
  # 1. Vérification des packages requis
  # =========================
  required_pkgs <- c("data.table", "stringi", "writexl", "readxl") # liste des packages nécessaires
  missing_pkgs <- required_pkgs[!vapply(required_pkgs, requireNamespace, logical(1), quietly=TRUE)] # check packages installés
  if(length(missing_pkgs) > 0) stop("Installez les packages : ", paste(missing_pkgs, collapse=", ")) # stop si manquants
  
  # =========================
  # 2. Vérification fichier et dossier
  # =========================
  if(is.null(file_path)) file_path <- file.choose()  # si non fourni, ouvre dialogue pour choisir fichier
  if(!file.exists(file_path)) stop("Fichier introuvable : ", file_path) # stop si fichier inexistant
  ext <- tolower(tools::file_ext(file_path)) #récupère l’extension en minuscules
  file_name <- basename(file_path)           #nom du fichier sans chemin
  file_base <- tools::file_path_sans_ext(file_name) #nom de base sans extension
  if(is.null(output_dir)) output_dir <- dirname(file_path) #dossier sortie = dossier source par défaut
  if(!dir.exists(output_dir)) #création dossier sortie si inexistant
    if(!tryCatch(dir.create(output_dir, recursive=TRUE), error=function(e) FALSE))#permet de gérer les warnings générés
      stop("Impossible de créer le dossier de sortie") #stop le génération du code et indique un message d'erreur 
  
  # =========================
  # 3. Fonctions utilitaires
  # =========================
  # Crée un chemin unique si le fichier existe déjà
  make_unique_path <- function(path) {
    if(!file.exists(path)) return(path) #retourne tel quel si non existant
    base <- tools::file_path_sans_ext(path) #nom sans extension
    ext <- tools::file_ext(path)            #extension
    i <- 1
    repeat {
      new_path <- paste0(base,"_",i,".",ext) #ajoute suffixe _i
      if(!file.exists(new_path)) return(new_path) #retourne chemin unique
      i <- i + 1
    }
  }
  
  # Détecte le meilleur séparateur CSV parmi plusieurs candidats
  guess_best_separator <- function(file_path, candidates, n_lines=50) {
    lines <- readLines(file_path, n=n_lines, warn=FALSE, encoding="UTF-8") #lit un échantillon du fichier
    best_sep <- candidates[1] #initialisation du séparateur
    best_score <- -Inf        #score initial
    for(sep in candidates) {  #test de chaque séparateur
      cols <- lengths(strsplit(lines, sep, fixed=TRUE)) #compte colonnes par ligne
      score <- mean(cols) - sd(cols)                   #score : moyenne - écart type
      if(score > best_score) { best_score <- score; best_sep <- sep } #garde meilleur score
    }
    col_counts <- lengths(strsplit(lines, best_sep, fixed=TRUE)) #colonnes finales
    if(sd(col_counts) > 0 && !ignore_col_warnings) warning("Certaines lignes CSV ont colonnes incohérentes") #warning si irrégularités
    if(verbose) message("Séparateur détecté : '", best_sep, "'") #message si verbose
    return(best_sep) #retourne le séparateur choisi
  }
  
  # Détection automatique des encodages probables
  detect_encodings <- function(file_path, sample_size) {
    raw_data <- readBin(file_path,"raw",sample_size) #lit un échantillon en binaire
    enc_guess <- tryCatch(stringi::stri_enc_detect2(raw_data), error=function(e) NULL) #détection encodage
    if(is.null(enc_guess)) return(c("UTF-8","Latin1","Windows-1252","ISO-8859-1")) #fallback si échec
    enc_df <- enc_guess[[1]] #data.frame encodages détectés
    encs <- unique(c(enc_df$Encoding[order(-enc_df$Confidence)], #tri par confiance décroissante
                     "UTF-8","Latin1","Windows-1252","ISO-8859-1")) #ajoute fallback classiques
    return(encs) #retourne vecteur encodages
  }
  
  # Enregistre les encodages testés dans un log
  log_encodings <- function(enc_list, file=NULL) if(!is.null(file)) writeLines(enc_list, con=file)
  
  # =========================
  # 4. Cas CSV / TXT / TSV
  # =========================
  if(ext %in% c("csv","txt","tsv")) {
    sep <- guess_best_separator(file_path, csv_separators) #détecte séparateur
    encodings_to_try <- if(!is.null(encoding)) encoding else detect_encodings(file_path, enc_sample_size) #liste encodages
    log_enc <- character(0) #log initial
    data <- NULL           #data.frame vide
    
    # Boucle sur encodages détectés
    for(enc in encodings_to_try) {
      log_enc <- c(log_enc, enc) #ajoute au log
      data <- tryCatch(
        data.table::fread(file_path, encoding=enc, sep=sep, showProgress=verbose), #tentative lecture
        error=function(e) NULL
      )
      if(!is.null(data)) { if(verbose) message("Lecture réussie avec encodage ", enc); break } #succès
    }
    
    # Tentative avec force_encoding si auto échoue
    if(is.null(data) && !is.null(force_encoding)) {
      data <- tryCatch(
        data.table::fread(file_path, encoding=force_encoding, sep=sep, showProgress=verbose),
        error=function(e) NULL
      )
      if(!is.null(data) && verbose) message("Lecture réussie avec force_encoding = ", force_encoding)
      log_enc <- c(log_enc, force_encoding)
    }
    
    # Tentative interactive si auto et force échouent
    if(is.null(data) && interactive_on_fail && interactive()) {
      repeat {
        user_enc <- readline("Entrez un encodage à tester manuellement (ou vide pour abandonner) : ")
        if(!nzchar(user_enc)) stop("Aucun encodage valide trouvé") #vérifie si la chaîne est vide, si elle l'est il y a arrêt du programme et affichage du message d'erreur
        data <- tryCatch(
          data.table::fread(file_path, encoding=user_enc, sep=sep, showProgress=verbose),
          error=function(e) NULL
        )
        if(!is.null(data)) { if(verbose) message("Lecture réussie avec encodage manuel ", user_enc); log_enc <- c(log_enc, user_enc); break }
      }
    }
    
    # Stop si aucun encodage ne fonctionne
    if(is.null(data)) stop("Impossible de lire le fichier. Encodages testés : ", paste(log_enc, collapse=", "))
    log_encodings(log_enc, log_file) #enregistre log
    
    # Écriture CSV sortie
    output_path <- make_unique_path(file.path(output_dir, paste0(file_base, if(bom) "_utf8_bom" else "_utf8",".csv")))
    data.table::fwrite(data, file=output_path, bom=bom, sep=sep_out, quote=TRUE, na="")
    if(verbose) message("Fichier CSV écrit : ", output_path)
  }
  
  # =========================
  # 5. Cas Excel
  # =========================
  else if(ext %in% c("xls","xlsx")) {
    file_size <- file.info(file_path)$size / (1024^2) #taille en Mo
    if(file_size>100) warning("Excel >100 Mo : writexl peut échouer. Openxlsx recommandé") #warning gros fichiers
    sheets <- readxl::excel_sheets(file_path) #liste des feuilles
    data_list <- lapply(sheets, function(sh) readxl::read_excel(file_path, sheet=sh)) # lecture de chaque feuille
    names(data_list) <- sheets
    output_path <- make_unique_path(file.path(output_dir, paste0(file_base,"_utf8.xlsx"))) # chemin sortie
    writexl::write_xlsx(data_list, output_path) # écriture
    warning("Formules, macros et mise en forme Excel perdues. Pour tout conserver : openxlsx ou export manuel")
    if(verbose) message("Fichier Excel réécrit : ", output_path)
  }
  
  # =========================
  # 6. Extension non supportée
  # =========================
  else stop("Extension non supportée : ", ext)
  
  return(output_path) # retourne chemin final
}