import Foundation
import CoreGraphics

/// The "Fleet Orders Q3" workbook used throughout the design rounds. Loaded on first launch
/// so the app opens with something to play with.
enum SampleData {
    static func workbook() -> Workbook {
        var orders = Sheet(name: "Orders", columns: [
            Column(name: "Order", type: .text, width: 80),
            Column(name: "Region", type: .text, width: 84),
            Column(name: "Product", type: .text, width: 200),
            Column(name: "Units", type: .number, width: 60),
            Column(name: "Unit price", type: .currency, width: 92),
            Column(name: "Revenue", type: .currency, width: 100, formulaTemplate: "=D{row}*E{row}"),
            Column(name: "Margin", type: .percent, width: 70),
            Column(name: "Status", type: .text, width: 106, colorByValue: true),
            Column(name: "Notes", type: .text, width: 170)
        ], rows: [])
        let raw: [(String, String, String, Double, Double, Double, String, String)] = [
            ("OR-1041","West","Adult patient simulator",4,38500,0.41,"Shipped","Expedited freight"),
            ("OR-1042","East","IV training arm",12,1450,0.52,"Delivered",""),
            ("OR-1043","Central","Airway management trainer",6,2980,0.47,"Invoiced","PO attached"),
            ("OR-1044","South","Infant simulator",2,24900,0.39,"Pending","Awaiting credit check"),
            ("OR-1045","EMEA","Vital signs monitor",10,3200,0.35,"Shipped",""),
            ("OR-1046","West","Ultrasound phantom",3,7600,0.44,"Backorder","ETA Nov 18"),
            ("OR-1047","APAC","Service plan, 1 yr",8,4100,0.71,"Invoiced","Renewal"),
            ("OR-1048","East","Suture task trainer",25,320,0.58,"Delivered","Classroom bundle"),
            ("OR-1049","Central","Debrief camera kit",5,5400,0.36,"Shipped",""),
            ("OR-1050","South","Moulage kit",14,210,0.62,"Delivered",""),
            ("OR-1051","West","Tablet controller",9,1250,0.49,"Pending","Firmware 4.2 required"),
            ("OR-1052","EMEA","Adult patient simulator",1,38500,0.41,"Invoiced","Demo unit"),
            ("OR-1053","APAC","AED trainer",30,480,0.55,"Shipped",""),
            ("OR-1054","East","Airway management trainer",4,2980,0.47,"Backorder","ETA Nov 22"),
            ("OR-1055","Central","Infant simulator",3,24900,0.39,"Shipped","Expedited freight"),
            ("OR-1056","West","Service plan, 3 yr",6,10800,0.74,"Invoiced",""),
            ("OR-1057","South","Vital signs monitor",7,3200,0.35,"Delivered",""),
            ("OR-1058","EMEA","Ultrasound phantom",2,7600,0.44,"Pending","Customs paperwork"),
            ("OR-1059","APAC","Suture task trainer",40,320,0.58,"Shipped",""),
            ("OR-1060","East","Debrief camera kit",3,5400,0.36,"Invoiced",""),
            ("OR-1061","Central","Tablet controller",11,1250,0.49,"Delivered","")
        ]
        for (i, r) in raw.enumerated() {
            orders.rows.append([.text(r.0), .text(r.1), .text(r.2), .number(r.3), .number(r.4), .formula("=D\(i + 2)*E\(i + 2)"), .number(r.5), .text(r.6), r.7.isEmpty ? .empty : .text(r.7)])
        }

        var inventory = Sheet(name: "Inventory", columns: [
            Column(name: "Product", type: .text, width: 200), Column(name: "On hand", type: .number, width: 80),
            Column(name: "Reserved", type: .number, width: 80), Column(name: "Reorder", type: .number, width: 80), Column(name: "Vendor", type: .text, width: 120)
        ], rows: [])
        let inv: [(String, Double, Double, Double, String)] = [
            ("Adult patient simulator",6,5,2,"Internal"),("Infant simulator",4,5,2,"Internal"),("IV training arm",38,12,20,"Ardent"),
            ("Airway management trainer",11,10,6,"Ardent"),("Ultrasound phantom",0,5,3,"Blue Phantom"),("Vital signs monitor",22,17,10,"Internal"),
            ("Suture task trainer",140,65,50,"Ardent"),("AED trainer",52,30,25,"Laerdal"),("Debrief camera kit",7,8,4,"Internal"),("Moulage kit",80,14,20,"Ardent")
        ]
        for r in inv { inventory.rows.append([.text(r.0), .number(r.1), .number(r.2), .number(r.3), .text(r.4)]) }

        var pricing = Sheet(name: "Pricing", columns: [
            Column(name: "SKU", type: .text, width: 200), Column(name: "List", type: .currency, width: 90),
            Column(name: "Floor", type: .currency, width: 90, formulaTemplate: "=B{row}*(1-D{row})"), Column(name: "Discount", type: .percent, width: 80)
        ], rows: [])
        let pr: [(String, Double)] = [("Adult patient simulator",38500),("Infant simulator",24900),("Service plan, 3 yr",10800),("Ultrasound phantom",7600),("Debrief camera kit",5400),("Service plan, 1 yr",4100),("Vital signs monitor",3200),("Airway management trainer",2980),("Tablet controller",1250)]
        for (i, r) in pr.enumerated() { pricing.rows.append([.text(r.0), .number(r.1), .formula("=B\(i + 2)*(1-D\(i + 2))"), .number(0.1)]) }

        let gridW: CGFloat = 40 + orders.columns.reduce(0) { $0 + $1.width } + 3
        var wb = Workbook(sheets: [orders, inventory, pricing], canvases: [])
        wb.canvases = [
            Canvas(name: "Orders", cards: [
                Card(kind: .grid(sheetID: orders.id), origin: .zero),
                Card(kind: .pivot(PivotConfig(sheetID: orders.id, rowField: "Region", valueField: "Revenue")), origin: CGPoint(x: gridW + 48, y: 0)),
                Card(kind: .chart(ChartConfig(sheetID: orders.id, type: .bar, xField: "Region", yField: "Revenue")), origin: CGPoint(x: gridW + 48, y: 260))
            ]),
            Canvas(name: "Inventory", cards: [Card(kind: .grid(sheetID: inventory.id), origin: .zero)]),
            Canvas(name: "Pricing", cards: [Card(kind: .grid(sheetID: pricing.id), origin: .zero)])
        ]
        return wb
    }
}
