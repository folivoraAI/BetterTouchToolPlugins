//
//  MyCpuUsage.swift
//  BTTStreamDeckPluginCPUUsage


import Foundation

// Credit: https://stackoverflow.com/a/53901721/1068087
// CPU usage credit VenoMKO: https://stackoverflow.com/a/6795612/1033581
class MyCpuUsage {
    var cpuInfo: processor_info_array_t?
    var prevCpuInfo: processor_info_array_t?
    var numCpuInfo: mach_msg_type_number_t = 0
    var numPrevCpuInfo: mach_msg_type_number_t = 0
    var numCPUs: uint = 0
    var updateTimer: Timer?
    let CPUUsageLock: NSLock = NSLock()
    var cpuLoadBlock: ((CGFloat) -> Swift.Void)?

    init() {
       
    }
    
    func startMonitoring(_ loadBlock: @escaping ((CGFloat) -> Swift.Void)) {
        let mibKeys: [Int32] = [ CTL_HW, HW_NCPU ]
        // sysctl Swift usage credit Matt Gallagher: https://github.com/mattgallagher/CwlUtils/blob/master/Sources/CwlUtils/CwlSysctl.swift
        mibKeys.withUnsafeBufferPointer() { mib in
            var sizeOfNumCPUs: size_t = MemoryLayout<uint>.size
            let status = sysctl(processor_info_array_t(mutating: mib.baseAddress), 2, &numCPUs, &sizeOfNumCPUs, nil, 0)
            if status != 0 {
                numCPUs = 1
            }
        }
        updateTimer = Timer.scheduledTimer(timeInterval: 3, target: self, selector: #selector(updateInfo), userInfo: nil, repeats: true)

        cpuLoadBlock = loadBlock
    }

    @objc func updateInfo(_ timer: Timer) {
       

        var numCPUsU: natural_t = 0
        let err: kern_return_t = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &numCPUsU, &cpuInfo, &numCpuInfo);
        if err == KERN_SUCCESS {
            CPUUsageLock.lock()
            guard let cpuInfo = cpuInfo else {
                return
            }

            var totalInUse: Float = 0
            for i in 0 ..< Int32(numCPUs) {
                var inUse: Int32
                var total: Int32
                if let prevCpuInfo = prevCpuInfo {
                    inUse = cpuInfo[Int(CPU_STATE_MAX * i + CPU_STATE_USER)]
                        - prevCpuInfo[Int(CPU_STATE_MAX * i + CPU_STATE_USER)]
                        + cpuInfo[Int(CPU_STATE_MAX * i + CPU_STATE_SYSTEM)]
                        - prevCpuInfo[Int(CPU_STATE_MAX * i + CPU_STATE_SYSTEM)]
                        + cpuInfo[Int(CPU_STATE_MAX * i + CPU_STATE_NICE)]
                        - prevCpuInfo[Int(CPU_STATE_MAX * i + CPU_STATE_NICE)]
                    total = inUse + (cpuInfo[Int(CPU_STATE_MAX * i + CPU_STATE_IDLE)]
                        - prevCpuInfo[Int(CPU_STATE_MAX * i + CPU_STATE_IDLE)])
                } else {
                    inUse = cpuInfo[Int(CPU_STATE_MAX * i + CPU_STATE_USER)]
                        + cpuInfo[Int(CPU_STATE_MAX * i + CPU_STATE_SYSTEM)]
                        + cpuInfo[Int(CPU_STATE_MAX * i + CPU_STATE_NICE)]
                    total = inUse + cpuInfo[Int(CPU_STATE_MAX * i + CPU_STATE_IDLE)]
                }

             //   print(String(format: "Core: %u Usage: %f", i, Float(inUse) / Float(total)))
                totalInUse = totalInUse + (Float(inUse) / Float(total))
            }
            
            //print(String(format: "Total %f", totalInUse / Float(numCPUs)))

            CPUUsageLock.unlock()
            cpuLoadBlock?(CGFloat(totalInUse / Float(numCPUs)))
            if let prevCpuInfo = prevCpuInfo {
                // vm_deallocate Swift usage credit rsfinn: https://stackoverflow.com/a/48630296/1033581
                let prevCpuInfoSize: size_t = MemoryLayout<integer_t>.stride * Int(numPrevCpuInfo)
                vm_deallocate(mach_task_self_, vm_address_t(bitPattern: prevCpuInfo), vm_size_t(prevCpuInfoSize))
            }

            prevCpuInfo = cpuInfo
            numPrevCpuInfo = numCpuInfo
            numCpuInfo = 0
        } else {
            print("Error!")
        }
    }
}
