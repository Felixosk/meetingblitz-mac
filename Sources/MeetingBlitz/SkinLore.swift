import Foundation

/// Die Geschichte hinter jedem Flugobjekt, plus eine Quelle zum Nachlesen.
///
/// WARUM DAS HIER STEHT: Jedes der 27 Motive bildet ein ECHTES Vorbild ab, und
/// genau das ist der Reiz. Ohne diesen Text ist ein Narco-U-Boot nur ein graues
/// Boot; mit ihm ist es das Boot, das im Januar 2026 mit neun Tonnen Kokain vor
/// den Azoren aufgebracht wurde.
///
/// 🚨 ALLE ZAHLEN SIND GEGEN QUELLEN GEPRÜFT (21.08.2026), nicht aus dem
/// Gedächtnis geschrieben. Dabei fielen mehrere verbreitete Irrtümer auf, die
/// hier bewusst NICHT wiederholt werden:
///   - Alvin fand 1977 Hydrothermalquellen, die Schwarzen Raucher erst 1979.
///   - Deep Blue gilt populär als größter je gefilmter Weißer Hai, das ist
///     fachlich umstritten und steht deshalb nicht als Tatsache da.
///   - Der Kugelfisch-"Rausch" der Delfine ist eine Deutung aus einer einzigen
///     Filmaufnahme, kein belegter Befund.
///   - Die Ohio-Klasse hat baulich 24 Rohre, seit 2017 sind wegen New START
///     nur 20 belegt.
///   - Der Ballonabschuss war der ERSTE Luft-Luft-Abschuss der F-22, nicht der
///     einzige.
/// Wer hier etwas ändert: erst die Quelle lesen, dann den Satz anfassen.
///
/// Die Quelle ist bewusst pro Sprache getrennt, damit ein deutscher Nutzer
/// nicht auf einem englischen Wikipedia-Artikel landet.
struct SkinLore {
    let de: String
    let en: String
    let sourceDE: String
    let sourceEN: String

    static let byID: [String: SkinLore] = [

        "01-narco-sub": SkinLore(
            de: """
                Im Januar 2026 fing die portugiesische Polizei 230 Seemeilen vor den Azoren \
                ein selbstgebautes Halbtauchboot ab, an Bord geschätzt neun Tonnen Kokain. \
                Es war der größte Kokainfund in der Geschichte Portugals. Vier Männer hatten \
                wochenlang in dem engen Rumpf über den Atlantik ausgehalten.
                """,
            en: """
                In January 2026 Portuguese police intercepted a home-built semi-submersible \
                230 nautical miles off the Azores, carrying an estimated nine tonnes of \
                cocaine, the largest such seizure in Portuguese history. Four men had spent \
                weeks crossing the Atlantic inside the cramped hull.
                """,
            sourceDE: "https://de.nachrichten.yahoo.com/razzia-hoher-see-halbtaucherboot-neun-055554684.html",
            sourceEN: "https://www.cbsnews.com/news/narco-sub-sinks-record-haul-cocaine-seized-azores/"),

        "02-typhoon": SkinLore(
            de: """
                Die sowjetische Typhoon-Klasse ist das größte U-Boot, das je gebaut wurde: \
                rund 173 Meter lang, getaucht 48.000 Tonnen, bis zu 160 Mann Besatzung. \
                In dem gewaltigen Rumpf fanden sogar eine Sauna und ein Tauchbecken Platz. \
                Das letzte Boot wurde 2023 außer Dienst gestellt.
                """,
            en: """
                The Soviet Typhoon class is the largest submarine ever built: about 173 metres \
                long, 48,000 tonnes submerged, a crew of up to 160. The enormous hull even had \
                room for a sauna and a plunge pool. The last boat was retired in 2023.
                """,
            sourceDE: "https://de.wikipedia.org/wiki/Projekt_941",
            sourceEN: "https://en.wikipedia.org/wiki/Typhoon-class_submarine"),

        "03-u96": SkinLore(
            de: """
                Auf U 96 fuhr Lothar-Günther Buchheim 1941 als Kriegsberichterstatter mit. \
                Aus den Erlebnissen wurde 1973 der Roman „Das Boot" und 1981 der Film, damals \
                die teuerste deutsche Produktion überhaupt und für sechs Oscars nominiert. \
                Kaum ein U-Boot hat das Bild vom Leben unter Wasser stärker geprägt.
                """,
            en: """
                Lothar-Günther Buchheim sailed on U 96 as a war correspondent in 1941. His \
                experience became the 1973 novel "Das Boot" and the 1981 film, at the time the \
                most expensive German production ever made and nominated for six Oscars. Few \
                submarines shaped the popular image of life underwater more.
                """,
            sourceDE: "https://de.wikipedia.org/wiki/Das_Boot_(Film)",
            sourceEN: "https://en.wikipedia.org/wiki/Das_Boot_(novel)"),

        "04-yellow-submarine": SkinLore(
            de: """
                „Yellow Submarine" erschien 1966 auf dem Beatles-Album Revolver, gesungen von \
                Ringo Starr, und wurde zu einem der bekanntesten Kinderlieder der Welt. 1968 \
                folgte der Zeichentrickfilm, dessen Bildwelt der deutsche Grafiker Heinz \
                Edelmann prägte.
                """,
            en: """
                "Yellow Submarine" appeared in 1966 on the Beatles album Revolver, sung by \
                Ringo Starr, and became one of the best known children's songs in the world. \
                The animated film followed in 1968, its visual world shaped by German designer \
                Heinz Edelmann.
                """,
            sourceDE: "https://de.wikipedia.org/wiki/Yellow_Submarine_(Lied)",
            sourceEN: "https://en.wikipedia.org/wiki/Yellow_Submarine_(song)"),

        "05-nautilus": SkinLore(
            de: """
                Jules Verne erfand die Nautilus 1870 in „20.000 Meilen unter dem Meer", lange \
                bevor es brauchbare U-Boote gab. Fast ein Jahrhundert später trug das erste \
                Atom-U-Boot der Welt denselben Namen und unterquerte 1958 als erstes Schiff \
                überhaupt den Nordpol.
                """,
            en: """
                Jules Verne invented the Nautilus in 1870 in "Twenty Thousand Leagues Under the \
                Seas", long before workable submarines existed. Almost a century later the \
                world's first nuclear submarine carried the same name and in 1958 became the \
                first vessel ever to cross under the North Pole.
                """,
            sourceDE: "https://de.wikipedia.org/wiki/Nautilus_(Jules_Verne)",
            sourceEN: "https://en.wikipedia.org/wiki/USS_Nautilus_(SSN-571)"),

        "06-alvin": SkinLore(
            de: """
                Das Forschungstauchboot Alvin barg 1966 eine bei Palomares verlorene \
                Wasserstoffbombe vom Meeresgrund, fand 1977 vor Galapagos die ersten \
                Tiefseequellen mit eigenem Ökosystem und tauchte 1986 zum Wrack der Titanic. \
                Die berühmten Schwarzen Raucher entdeckte es zwei Jahre nach den Quellen, 1979.
                """,
            en: """
                The research submersible Alvin recovered a lost hydrogen bomb off Palomares in \
                1966, found the first deep-sea vents with their own ecosystem near the Galápagos \
                in 1977, and dived to the wreck of the Titanic in 1986. The famous black smokers \
                came two years after those first vents, in 1979.
                """,
            sourceDE: "https://de.wikipedia.org/wiki/Alvin_(DSV-2)",
            sourceEN: "https://en.wikipedia.org/wiki/DSV_Alvin"),

        "07-triton": SkinLore(
            de: """
                Mit einem Tauchboot dieses Herstellers erreichte Victor Vescovo 2019 den \
                tiefsten Punkt der Erde, das Challengertief im Marianengraben, in 10.928 Metern. \
                Es ist der tiefste bemannte Tauchgang der Geschichte. Die durchsichtige \
                Acrylkugel hält dabei einem Druck von über tausend Bar stand.
                """,
            en: """
                In a submersible from this builder, Victor Vescovo reached the deepest point on \
                Earth in 2019, the Challenger Deep in the Mariana Trench, at 10,928 metres. It \
                remains the deepest crewed dive in history. The clear acrylic sphere withstands \
                a pressure of over a thousand bar.
                """,
            sourceDE: "https://www.watson.ch/wissen/natur/307979913-tiefseeforscher-stellt-neuen-tauchrekord-auf-und-findet-plastikmuell",
            sourceEN: "https://en.wikipedia.org/wiki/DSV_Limiting_Factor"),

        "08-ente": SkinLore(
            de: """
                Am 10. Januar 1992 ging im Nordpazifik ein Container mit 28.800 Badetieren über \
                Bord. Die Enten trieben jahrzehntelang um die Welt, einzelne erreichten nach \
                rund fünfzehn Jahren Großbritannien. Meeresforscher nutzten die Fundmeldungen, \
                um Strömungen zu berechnen.
                """,
            en: """
                On 10 January 1992 a container holding 28,800 bath toys went overboard in the \
                North Pacific. The ducks drifted around the world for decades, some reaching \
                Britain after roughly fifteen years. Oceanographers used the sighting reports to \
                model ocean currents.
                """,
            sourceDE: "https://www.tagesspiegel.de/wissen/meeresforschung-mit-quietscheentchen-6596422.html",
            sourceEN: "https://en.wikipedia.org/wiki/Friendly_Floatees_spill"),

        "09-pottwal": SkinLore(
            de: """
                Am 20. November 1820 rammte ein Pottwal das Walfangschiff Essex im Pazifik und \
                versenkte es. Der Bericht des Ersten Maats Owen Chase kam Herman Melville \
                Jahrzehnte später in die Hände und wurde zur Vorlage für „Moby-Dick".
                """,
            en: """
                On 20 November 1820 a sperm whale rammed and sank the whaleship Essex in the \
                Pacific. First mate Owen Chase's account reached Herman Melville decades later \
                and became the model for "Moby-Dick".
                """,
            sourceDE: "https://de.wikipedia.org/wiki/Essex_(Schiff,_1800)",
            sourceEN: "https://www.smithsonianmag.com/smart-news/inside-the-terrifying-true-story-of-the-sperm-whale-that-sank-the-whale-ship-essex-and-inspired-herman-melvilles-moby-dick-180985362/"),

        "10-hai": SkinLore(
            de: """
                „Deep Blue" wurde 2013 vor der mexikanischen Insel Guadalupe gefilmt und gilt \
                vielen als der größte je gefilmte Weiße Hai. Belegt ist das nicht: die Schätzung \
                von rund sechs Metern beruht auf dem bloßen Augenmaß, nicht auf einer Messung. \
                Weibchen dieser Art werden deutlich größer als Männchen.
                """,
            en: """
                "Deep Blue" was filmed off Mexico's Guadalupe Island in 2013 and is widely called \
                the largest great white ever filmed. That is not established: the estimate of \
                around six metres rests on visual judgement, not measurement. Females of the \
                species grow considerably larger than males.
                """,
            sourceDE: "https://www.just-wanderlust.com/tiere-natur-meer/haie/groesster-weisser-hai-der-welt-hat-deep-blue-konkurrenz-bekommen/",
            sourceEN: "https://en.wikipedia.org/wiki/Deep_Blue_(great_white_shark)"),

        "11-orca": SkinLore(
            de: """
                Seit Mai 2020 rammen Orcas vor Gibraltar und Portugal gezielt die Ruder von \
                Segelbooten. Über 700 Begegnungen sind dokumentiert, mehrere Boote sind \
                gesunken. Verletzt wurde bislang kein Mensch, und warum die Tiere es tun, ist \
                bis heute ungeklärt.
                """,
            en: """
                Since May 2020 orcas off Gibraltar and Portugal have been deliberately ramming \
                the rudders of sailing boats. More than 700 encounters are documented and several \
                boats have sunk. No person has been hurt so far, and why the animals do it \
                remains unexplained.
                """,
            sourceDE: "https://de.whales.org/2026/07/07/orca-interaktionen-vor-gibraltar/",
            sourceEN: "https://en.wikipedia.org/wiki/Iberian_orca_attacks"),

        "12-oktopus": SkinLore(
            de: """
                Krake Paul aus dem Sea Life in Oberhausen sagte bei der WM 2010 alle acht Spiele \
                richtig voraus, das Finale eingeschlossen. Über EM und WM zusammen lag er bei \
                zwölf von vierzehn Treffern. Er wählte, indem er sich für eine von zwei \
                Futterboxen mit Landesflagge entschied.
                """,
            en: """
                Paul the octopus at Sea Life Oberhausen predicted all eight matches correctly at \
                the 2010 World Cup, the final included. Across that tournament and the 2008 Euros \
                he got twelve of fourteen right. He chose by picking one of two feeding boxes \
                marked with a national flag.
                """,
            sourceDE: "https://de.wikipedia.org/wiki/Paul_(Krake)",
            sourceEN: "https://en.wikipedia.org/wiki/Paul_the_Octopus"),

        "13-delfin": SkinLore(
            de: """
                Fungie tauchte 1983 in der Bucht von Dingle in Irland auf und begleitete dort \
                37 Jahre lang die Boote, ohne je zu einer Gruppe zu gehören. 2019 kam er als \
                ältester bekannter Einzelgänger-Delfin ins Guinness-Buch. Im Oktober 2020 \
                verschwand er spurlos.
                """,
            en: """
                Fungie appeared in Dingle Bay in Ireland in 1983 and accompanied the boats there \
                for 37 years without ever joining a pod. In 2019 he entered the Guinness records \
                as the longest-living solitary dolphin known. In October 2020 he vanished without \
                a trace.
                """,
            sourceDE: "https://www.20min.ch/story/findet-fungie-439013634323",
            sourceEN: "https://en.wikipedia.org/wiki/Fungie"),

        "14-schildkroete": SkinLore(
            de: """
                Die Karettschildkröte Yoshi kam 1997 mit zwei Kilo Gewicht in ein Aquarium in \
                Kapstadt und wurde nach zwanzig Jahren mit einem Sender ausgewildert. Sie schwamm \
                bis vor Australien: 40.011 Kilometer in 1.003 Tagen, die längste je per Satellit \
                verfolgte Tierwanderung.
                """,
            en: """
                The loggerhead turtle Yoshi arrived at a Cape Town aquarium in 1997 weighing two \
                kilos and was released with a tracker after twenty years. She swam all the way to \
                Australia: 40,011 kilometres in 1,003 days, the longest animal migration ever \
                tracked by satellite.
                """,
            sourceDE: "https://www.wwf.ch/de/stories/die-weltreise-einer-meeresschildkroete",
            sourceEN: "https://www.aquarium.co.za/news/yoshi-the-loggerhead-turtle-sends-her-last-transmission-after-40-000km-swim"),

        "15-kugelfisch": SkinLore(
            de: """
                Die BBC-Doku „Dolphins: Spy in the Pod" filmte 2014 junge Delfine, die einen \
                Kugelfisch minutenlang herumreichten und danach benommen wirkten. Daraus wurde \
                die Geschichte vom Rausch. Belegt ist sie nicht: Tetrodotoxin ist ein Nervengift, \
                und es gibt nur diese eine Beobachtung.
                """,
            en: """
                The BBC documentary "Dolphins: Spy in the Pod" filmed young dolphins in 2014 \
                passing a pufferfish between them for minutes and appearing dazed afterwards. \
                That became the story of dolphins getting high. It is not established: \
                tetrodotoxin is a nerve toxin, and this is a single observation.
                """,
            sourceDE: "https://scienceblogs.de/meertext/2014/01/21/delphin-verhaltensforschung-halbstarke-delphine-im-kugelfisch-drogenrausch/",
            sourceEN: "https://grist.org/living/dolphins-arent-getting-high-on-pufferfish/"),

        "16-papierboot": SkinLore(
            de: """
                Das gefaltete Papierboot ist älter als die meisten denken: In Japan ist es 1713 \
                belegt, in Europa 1840. Seine bekannteste Rolle bekam es 1986 in Stephen Kings \
                „Es", wo Georgies Boot in den Rinnstein treibt.
                """,
            en: """
                The folded paper boat is older than most people assume: documented in Japan in \
                1713 and in Europe in 1840. Its most famous appearance came in 1986 in Stephen \
                King's "It", where Georgie's boat drifts into the gutter.
                """,
            sourceDE: "https://de.wikipedia.org/wiki/Es_(Roman)",
            sourceEN: "https://www.origamiheaven.com/historyofthepaperboat.htm"),

        "17-rakete": SkinLore(
            de: """
                Am 4. Oktober 1957 brachte eine umgebaute R-7 den Satelliten Sputnik 1 ins All \
                und eröffnete das Raumfahrtzeitalter. Die vier kegelförmigen Booster geben ihr \
                die charakteristische Tulpenform. Ihre Bauart fliegt bis heute als Sojus, mit \
                über 1.900 Starts die meistgeflogene Raketenfamilie überhaupt.
                """,
            en: """
                On 4 October 1957 a modified R-7 carried Sputnik 1 into orbit and opened the \
                space age. Its four conical boosters give it the characteristic tulip shape. The \
                design still flies today as the Soyuz, with over 1,900 launches the most-flown \
                rocket family ever built.
                """,
            sourceDE: "https://de.wikipedia.org/wiki/Semjorka",
            sourceEN: "https://en.wikipedia.org/wiki/R-7_(rocket_family)"),

        "18-ufo": SkinLore(
            de: """
                Am 8. Juli 1947 meldete der Militärflugplatz Roswell, man habe eine „fliegende \
                Scheibe" geborgen. Noch am selben Tag korrigierte das Militär auf einen \
                Wetterballon. 1994 räumte die US-Luftwaffe ein, es sei ein Ballon des geheimen \
                Projekts Mogul gewesen, das sowjetische Atomtests aufspüren sollte.
                """,
            en: """
                On 8 July 1947 the Roswell army airfield announced it had recovered a "flying \
                disc". The military corrected this to a weather balloon the same day. In 1994 the \
                US Air Force conceded it had been a balloon from the secret Project Mogul, built \
                to detect Soviet nuclear tests.
                """,
            sourceDE: "https://de.wikipedia.org/wiki/Roswell-Zwischenfall",
            sourceEN: "https://en.wikipedia.org/wiki/Roswell_incident"),

        "19-zeppelin": SkinLore(
            de: """
                Die Graf Zeppelin umrundete 1929 in 21 Tagen die Welt und legte in ihrer \
                Dienstzeit rund 1,7 Millionen Kilometer zurück, ohne dass je ein Passagier zu \
                Schaden kam. Das Ende der Ära kam trotzdem: 1937 verbrannte die Hindenburg in \
                Lakehurst, 36 Menschen starben.
                """,
            en: """
                The Graf Zeppelin circled the globe in 21 days in 1929 and covered around 1.7 \
                million kilometres in service without a single passenger ever being harmed. The \
                era ended anyway: in 1937 the Hindenburg burned at Lakehurst, killing 36 people.
                """,
            sourceDE: "https://wissenschafts-thurm.de/vor-90-jahren-eroeffnete-die-graf-zeppelin-den-touristischen-fernverkehr-mit-luftschiffen/",
            sourceEN: "https://en.wikipedia.org/wiki/LZ_127_Graf_Zeppelin"),

        "20-nessie": SkinLore(
            de: """
                Das berühmteste Nessie-Foto erschien 1934 in der Daily Mail und prägte sechzig \
                Jahre lang das Bild vom Ungeheuer. 1994 kam heraus, dass es gestellt war: ein \
                Spielzeug-U-Boot aus dem Kaufhaus mit einem aufgesetzten Kopf aus Holzmasse. Ein \
                U-Boot als Vorlage für ein Seeungeheuer.
                """,
            en: """
                The most famous Nessie photograph appeared in the Daily Mail in 1934 and shaped \
                the image of the monster for sixty years. In 1994 it emerged that it had been \
                staged: a toy submarine from a department store with a head modelled in wood \
                filler on top. A submarine posing as a sea monster.
                """,
            sourceDE: "https://www.photoscala.de/2007/10/03/wie-das-beruehmteste-nessie-foto-gefaelscht-wurde/",
            sourceEN: "https://hoaxes.org/photo_database/image/the_surgeons_photo/"),

        "21-finnwal": SkinLore(
            de: """
                Der Finnwal ist nach dem Blauwal das zweitgrößte Tier der Erde und wird über \
                zwanzig Meter lang. Seine Färbung ist auffällig unsymmetrisch: die rechte Seite \
                des Unterkiefers ist hell, die linke dunkel. Vermutlich hängt das mit seiner \
                Jagdtechnik zusammen, bei der er sich zur Seite dreht.
                """,
            en: """
                The fin whale is the second-largest animal on Earth after the blue whale and \
                grows over twenty metres long. Its colouring is strikingly asymmetric: the right \
                side of the lower jaw is pale, the left dark. This is thought to relate to its \
                hunting technique, in which it rolls onto its side.
                """,
            sourceDE: "https://de.wikipedia.org/wiki/Finnwal",
            sourceEN: "https://www.fisheries.noaa.gov/species/fin-whale"),

        "22-ohio": SkinLore(
            de: """
                Die Ohio-Klasse ist seit 1981 im Dienst und bildet das Rückgrat der \
                amerikanischen Abschreckung zur See. Gebaut wurden die Boote mit 24 Startrohren, \
                seit 2017 sind wegen des New-START-Vertrags nur noch 20 belegt. Größer sind \
                weltweit nur russische Boote.
                """,
            en: """
                The Ohio class has been in service since 1981 and forms the backbone of American \
                sea-based deterrence. The boats were built with 24 launch tubes; since 2017 only \
                20 are loaded under the New START treaty. Only Russian submarines are larger.
                """,
            sourceDE: "https://www.reservistenverband.de/magazin-loyal/zweitschlag-garantie-strategische-u-boote-als-mittel-der-abschreckung/",
            sourceEN: "https://en.wikipedia.org/wiki/Ohio-class_submarine"),

        "23-u48": SkinLore(
            de: """
                Der Typ VII ist der meistgebaute U-Boot-Typ der Geschichte: über 700 Boote \
                zwischen 1935 und 1945. Die gezackte Klinge am Bug ist eine Netzsäge, mit der \
                sich frühe Boote durch Hafensperren schneiden sollten. In der Praxis funktionierte \
                sie kaum und verschwand später wieder.
                """,
            en: """
                The Type VII is the most-built submarine class in history: over 700 boats between \
                1935 and 1945. The serrated blade at the bow is a net cutter, meant to let early \
                boats slice through harbour barriers. In practice it barely worked and later \
                disappeared again.
                """,
            sourceDE: "https://de.wikipedia.org/wiki/U-Boot-Klasse_VII",
            sourceEN: "https://en.wikipedia.org/wiki/Type_VII_submarine"),

        "24-klasse-212a": SkinLore(
            de: """
                Die Klasse 212 A war weltweit die erste mit Brennstoffzellenantrieb. Weil dabei \
                kein Sauerstoff von außen gebraucht wird, kann das Boot wochenlang getaucht \
                bleiben: U 32 fuhr 2013 achtzehn Tage am Stück unter Wasser über den Atlantik. \
                Der Rumpf besteht aus nicht magnetisierbarem Stahl.
                """,
            en: """
                The Type 212 A was the first class in the world with fuel-cell propulsion. Because \
                it needs no outside oxygen, the boat can stay submerged for weeks: in 2013 U 32 \
                crossed the Atlantic staying under for eighteen days straight. The hull is made of \
                non-magnetic steel.
                """,
            sourceDE: "https://de.wikipedia.org/wiki/U_32_(U-Boot,_2005)",
            sourceEN: "https://en.wikipedia.org/wiki/Type_212A_submarine"),

        "25-f22-raptor": SkinLore(
            de: """
                Die F-22 fliegt seit 2005, und fast achtzehn Jahre lang schoss sie nie etwas ab. \
                Der erste Abschuss kam im Februar 2023 vor South Carolina, und das Ziel war ein \
                chinesischer Spionageballon. In derselben Woche folgten zwei weitere Ballons. Ein \
                bemanntes Flugzeug war nie darunter.
                """,
            en: """
                The F-22 has flown since 2005 and for almost eighteen years shot nothing down. Its \
                first kill came in February 2023 off South Carolina, and the target was a Chinese \
                spy balloon. Two more balloons followed that same week. None of them was a crewed \
                aircraft.
                """,
            sourceDE: "https://www.businessinsider.de/politik/nach-fast-zwei-jahrzehnten-im-dienst-die-f-22-ihre-ersten-luft-luft-abschuesse-verbucht-allerdings-nicht-gegen-die-ziele-fuer-deren-bekaempfung-sie-entwickelt-wurde-a/",
            sourceEN: "https://en.wikipedia.org/wiki/Lockheed_Martin_F-22_Raptor"),

        "26-eurofighter": SkinLore(
            de: """
                Der Eurofighter entstand als Gemeinschaftsprojekt von Deutschland, \
                Großbritannien, Italien und Spanien. In Deutschland stellt er die Alarmrotte: \
                zwei bewaffnete Maschinen müssen binnen einer Viertelstunde in der Luft sein. \
                Allein der Standort im Norden kam 2025 auf rund zwanzig Alarmstarts, meist gegen \
                russische Aufklärer über der Ostsee.
                """,
            en: """
                The Eurofighter was built as a joint project by Germany, Britain, Italy and Spain. \
                In Germany it flies quick reaction alert: two armed aircraft must be airborne \
                within fifteen minutes. The northern base alone scrambled around twenty times in \
                2025, mostly against Russian reconnaissance aircraft over the Baltic.
                """,
            sourceDE: "https://www.dbwv.de/ticker/zahl-der-starts-der-luftwaffen-alarmrotte-ist-gestiegen",
            sourceEN: "https://en.wikipedia.org/wiki/Eurofighter_Typhoon"),

        "27-uh60-blackhawk": SkinLore(
            de: """
                Beim Einsatz gegen Osama bin Laden 2011 flogen zwei heimlich umgebaute Black \
                Hawks. Einer verunglückte bei der Landung und wurde gesprengt, doch das Heck lag \
                außerhalb der Mauer und überstand die Sprengung. An diesem Trümmerstück wurde \
                erstmals sichtbar, dass es eine getarnte Version des Hubschraubers überhaupt gibt.
                """,
            en: """
                Two secretly modified Black Hawks flew the 2011 raid on Osama bin Laden. One \
                crashed on landing and was blown up, but the tail section lay outside the wall and \
                survived the demolition. That piece of wreckage was the first public evidence that \
                a stealth version of the helicopter existed at all.
                """,
            sourceDE: "https://augengeradeaus.net/2011/05/der-geheim-hubschrauber-fur-die-osama-aktion/",
            sourceEN: "https://theaviationist.com/2019/11/29/the-story-of-the-famous-renderings-of-the-secretive-stealth-black-hawk-revealed-by-the-osama-bin-laden-raid/"),
    ]
}

extension Skin {
    var lore: SkinLore? { SkinLore.byID[id] }

    /// Text und Quelle in der eingestellten App-Sprache. `nil`, wenn zu einem
    /// Motiv (noch) keine Geschichte hinterlegt ist, dann blendet die
    /// Oberfläche den Knopf einfach aus.
    var loreText: String? { lore.map { L.t($0.de, $0.en) } }
    var loreSource: URL? { lore.flatMap { URL(string: L.t($0.sourceDE, $0.sourceEN)) } }
}
