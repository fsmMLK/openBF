#=
Copyright 2018 INSIGNEO Institute for in silico Medicine

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

   http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
=#


"""
    runSimulation(input_filename::String; verbose::Bool=false, out_files::Bool=false)

Execute the simulation main loop.

Args:
    - `input_filename`: The name of the `.yml` input file.
    - `verbose`: Opt. Boolean flag for STDOUT. Default is `false`.
    - `out_files`: Opt. Boolean flag to control the `.out` files writing. Default `false`.
"""
function runSimulation(input_filename::String; verbose::Bool=false, out_files::Bool=false)
    data = loadSimulationFiles(input_filename)
    blood = buildBlood(data["blood"])

    verbose && println("Build $input_filename arterial network \n")

    jump = data["solver"]["jump"]

    vessels, edges = buildArterialNetwork(data["network"], blood, jump)
    makeResultsFolder(data)

    Ccfl = data["solver"]["Ccfl"]
    heart = vessels[1].heart
    total_time = data["solver"]["cycles"]*heart.cardiac_T
    timepoints = range(0, stop=heart.cardiac_T, length=jump)

    verbose && println("Start simulation \n")

    current_time = 0.0
    passed_cycles = 0

    verbose && (@printf("Solving cardiac cycle no: %d", passed_cycles + 1); starting_time = time_ns())

    counter = 1
    while true
        dt = calculateDeltaT(vessels, Ccfl)
        solveModel(vessels, edges, blood, dt, current_time)
        updateGhostCells(vessels)

        if current_time >= timepoints[counter]
            saveTempData(current_time, vessels, counter)
            counter += 1
        end

        if (current_time - heart.cardiac_T*passed_cycles) >= heart.cardiac_T &&
          (current_time - heart.cardiac_T*passed_cycles + dt) > heart.cardiac_T

            if passed_cycles + 1 > 1
                err = checkConvergence(edges, vessels)
                if verbose == true
                    if err > 100.0
                        @printf(" - Conv. error > 100%%\n")
                    else
                        @printf(" - Conv. error = %4.2f%%\n", err)
                    end
                end
            else
                err = 100.0
                verbose && @printf("\n")
            end

            transferTempToLast(vessels)

            out_files && transferLastToOut(vessels)

            if err <= data["solver"]["convergence tolerance"]
                break
            end

            passed_cycles += 1
            verbose && @printf("Solving cardiac cycle no: %d", passed_cycles + 1)

            timepoints = timepoints .+ heart.cardiac_T
            counter = 1
        end

        current_time += dt
        if current_time >= total_time
            passed_cycles += 1
            verbose && println("\nNot converged after $passed_cycles cycles, End!")
            break
        end
    end
    verbose && (@printf("\n"); ending_time = (time_ns() - starting_time)/1.0e9)
    verbose && println("Elapsed time = $ending_time seconds")

    writeResults(vessels)

    cd("..")
end
