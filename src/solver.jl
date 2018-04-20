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
    pressure(A :: Float64, A0 :: Float64, beta :: Float64, Pext :: Float64)

Compute pressure at a specific node by means of the linear-elastic constitutive
equation.
"""
function pressure(A :: Float64, A0 :: Float64, beta :: Float64, Pext :: Float64)
    return Pext + beta*(sqrt(A/A0) - 1.0)
end

# version with pre-computed `sqrt(A/A0)`
function pressure(s_A_over_A0 :: Float64, beta :: Float64, Pext :: Float64)
    return Pext + beta*(s_A_over_A0 - 1.0)
end


"""
    waveSpeed(A :: Float64, gamma :: Float64)

Compute pulse wave velocity at the given node.
"""
function waveSpeed(A :: Float64, gamma :: Float64)
    return sqrt(3*gamma*sqrt(A)*0.5)
end


"""
    calculateDeltaT(vessels :: Array{Vessel,1}, Ccfl :: Float64)

Compute global minimum Δt through CFL condition.
"""
function calculateDeltaT(vessels, Ccfl :: Float64)
    dt = 1.0
    for v in vessels
        Smax = 0.0
        for j in 1:v.M
            lambda = abs(v.u[j] + v.c[j])
            Smax < lambda && (Smax = lambda)
        end
        vessel_dt = v.dx*Ccfl/Smax
        dt > vessel_dt && (dt = vessel_dt)
    end
    return dt
end


"""
    solveModel(vessel :: Array){Vessel,1}, edges :: Array{Int,2}, blood :: Blood,
               dt :: Float64, current_time :: Float64)

Run the solver on each vessel one-by-one as listed in the .yml file.
"""
function solveModel(vessels :: Array{Vessel,1}, edges :: Array{Int,2}, blood :: Blood,
                    dt :: Float64, current_time :: Float64)
    for j in 1:size(edges)[1]
        i = edges[j,1]
        v = vessels[i]

        solveVessel(v, blood, dt, current_time)
        solveOutlet(j, v, blood, vessels, edges, dt)
    end
end


"""
    solveVessel(vessel :: Vessel, blood :: Blood, dt :: Float64, current_time :: Float64)

Apply inlet boundary condition (if any) and run MUSCL solver along the vessel.
"""
function solveVessel(vessel :: Vessel, blood :: Blood, dt :: Float64,
                     current_time :: Float64)
    if vessel.inlet
        setInletBC(current_time, dt, vessel)
    end

    muscl(vessel, dt, blood)
end


"""
    solveOutlet(j :: Int, vessel :: Vessel, blood :: Blood, vessels :: Array{Vessel,1},
                edges :: Array{Int,2})

Join vessel in case of junction or apply outlet boundary condition otherwise.
"""
function solveOutlet(j :: Int, vessel :: Vessel, blood :: Blood, vessels :: Array{Vessel,1},
                     edges :: Array{Int,2}, dt :: Float64)
    i = edges[j,1]
    t = edges[j,3]

    if vessel.outlet != "none"
        setOutletBC(dt, vessel)

    elseif size(find(edges[:,2] .== t))[1] == 2
        d1_i = find(edges[:,2] .== t)[1]
        d2_i = find(edges[:,2] .== t)[2]
        joinVessels(blood, vessel, vessels[d1_i], vessels[d2_i])

    elseif size(find(edges[:,3] .== t))[1] == 1
        d_i = find(edges[:,2] .== t)[1]
        joinVessels(blood, vessel, vessels[d_i])

    elseif size(find(edges[:,3] .== t))[1] == 2
        p1_i = find(edges[:,3] .== t)[1]
        p2_i = find(edges[:,3] .== t)[2]

        if maximum([p1_i, p2_i]) == i
            p2_i = minimum([p1_i, p2_i])
            d = find(edges[:,2] .== t)[1]
            solveAnastomosis(vessel, vessels[p2_i], vessels[d])
        end
    end
end


"""
    muscl(v :: Vessel, dt :: Float64, b :: Blood)

Run MUSCL solver along the vessel.
"""
function muscl(v :: Vessel, dt :: Float64, b :: Blood)
    v.vA[1] = v.U00A
    v.vA[end] = v.UM1A

    v.vQ[1] = v.U00Q
    v.vQ[end] = v.UM1Q

    for i = 2:v.M+1
        v.vA[i] = v.A[i-1]
        v.vQ[i] = v.Q[i-1]
    end

    v.slopesA = computeLimiter(v, v.vA, v.invDx, v.dU, v.slopesA)
    v.slopesQ = computeLimiter(v, v.vQ, v.invDx, v.dU, v.slopesQ)

    for i = 1:v.M+2
        slopeA_halfDx = v.slopesA[i]*v.halfDx
        v.Al[i] = v.vA[i] + slopeA_halfDx
        v.Ar[i] = v.vA[i] - slopeA_halfDx

        slopeQ_halfDX = v.slopesQ[i]*v.halfDx
        v.Ql[i] = v.vQ[i] + slopeQ_halfDX
        v.Qr[i] = v.vQ[i] - slopeQ_halfDX
    end

    v.Fl = computeFlux(v, v.Al, v.Ql, v.Fl)
    v.Fr = computeFlux(v, v.Ar, v.Qr, v.Fr)

    dxDt = v.dx/dt
    invDxDt = 1.0/dxDt

    for i = 1:v.M+1
        v.flux[1,i] = 0.5*(v.Fr[1,i+1] + v.Fl[1,i] - dxDt*(v.Ar[i+1] - v.Al[i]))
        v.flux[2,i] = 0.5*(v.Fr[2,i+1] + v.Fl[2,i] - dxDt*(v.Qr[i+1] - v.Ql[i]))
    end

    for i = 2:v.M+1
        v.uStar[1,i] = v.vA[i] + invDxDt*(v.flux[1,i-1] - v.flux[1,i])
        v.uStar[2,i] = v.vQ[i] + invDxDt*(v.flux[2,i-1] - v.flux[2,i])
    end

    v.uStar[1,1] = v.uStar[1,2]
    v.uStar[2,1] = v.uStar[2,2]
    v.uStar[1,end] = v.uStar[1,end-1]
    v.uStar[2,end] = v.uStar[2,end-1]

    v.slopesA = computeLimiter(v, v.uStar, 1, v.invDx, v.dU, v.slopesA)
    v.slopesQ = computeLimiter(v, v.uStar, 2, v.invDx, v.dU, v.slopesQ)

    for i = 1:v.M+2
        v.Al[i] = v.uStar[1,i] + v.slopesA[i]*v.halfDx
        v.Ar[i] = v.uStar[1,i] - v.slopesA[i]*v.halfDx

        v.Ql[i] = v.uStar[2,i] + v.slopesQ[i]*v.halfDx
        v.Qr[i] = v.uStar[2,i] - v.slopesQ[i]*v.halfDx
    end

    v.Fl = computeFlux(v, v.Al, v.Ql, v.Fl)
    v.Fr = computeFlux(v, v.Ar, v.Qr, v.Fr)

    for i = 1:v.M+1
        v.flux[1, i] = 0.5*(v.Fr[1,i+1] + v.Fl[1,i] - dxDt*(v.Ar[i+1] - v.Al[i]))
        v.flux[2, i] = 0.5*(v.Fr[2,i+1] + v.Fl[2,i] - dxDt*(v.Qr[i+1] - v.Ql[i]))
    end

    for i = 2:v.M+1
        v.A[i-1] = 0.5*(v.A[i-1] + v.uStar[1,i] + invDxDt*(v.flux[1,i-1] - v.flux[1,i]))
        v.Q[i-1] = 0.5*(v.Q[i-1] + v.uStar[2,i] + invDxDt*(v.flux[2,i-1] - v.flux[2,i]))
    end

    #source term
    for i = 1:v.M
        s_A_over_A0 = sqrt(v.A[i])*v.s_inv_A0[i]

        v.Q[i] += dt*b.rho_inv*( -v.viscT*v.Q[i]/v.A[i] + v.A[i]*(v.half_beta_dA0dx[i] - (s_A_over_A0 - 1.)*v.dTaudx[i]))

        v.P[i] = pressure(s_A_over_A0, v.beta[i], v.Pext)
        v.u[i] = v.Q[i]/v.A[i]
        v.c[i] = waveSpeed(v.A[i], v.gamma[i])
    end
end


"""
    computeFlux(v :: Vessel, A :: Array{Float64,1}, Q :: Array{Float64,1},
                Flux :: Array{Float64,2})
"""
function computeFlux(v :: Vessel, A :: Array{Float64,1}, Q :: Array{Float64,1},
                     Flux :: Array{Float64,2})
    for i in 1:v.M+2
        Flux[1,i] = Q[i]
        Flux[2,i] = Q[i]*Q[i]/A[i] + v.gamma_ghost[i]*A[i]*sqrt(A[i])
    end

    return Flux
end


"""
    maxMod(a :: Float64, b :: Float64)
"""
function maxMod(a :: Float64, b :: Float64)
    if a > b
        return a
    else
        return b
    end
end


"""
    minMod(a :: Float64, b :: Float64)
"""
function minMod(a :: Float64, b :: Float64)
    if a <= 0.0 || b <= 0.0
        return 0.0
    elseif a < b
        return a
    else
        return b
    end
end


"""
    superBee(v :: Vessel, dU :: Array{Float64,2}, slopes :: Array{Float64,1})
"""
function superBee(v :: Vessel, dU :: Array{Float64,2}, slopes :: Array{Float64,1})
    for i in 1:v.M+2
        s1 = minMod(dU[1,i], 2*dU[2,i])
        s2 = minMod(2*dU[1,i], dU[2,i])
        slopes[i] = maxMod(s1, s2)
    end

    return slopes
end


"""
    computeLimiter(v :: Vessel, U :: Array{Float64,1}, invDx :: Float64,
                   dU :: Array{Float64,2}, slopes :: Array{Float64,1})
"""
function computeLimiter(v :: Vessel, U :: Array{Float64,1}, invDx :: Float64,
                        dU :: Array{Float64,2}, slopes :: Array{Float64,1})
    for i = 2:v.M+2
        dU[1,i]   = (U[i] - U[i-1])*v.invDx
        dU[2,i-1] = dU[1,i]
    end

    return superBee(v, dU, slopes)
end


function computeLimiter(v :: Vessel, U :: Array{Float64,2}, idx :: Int,
                        invDx :: Float64, dU :: Array{Float64,2},
                        slopes :: Array{Float64,1})
    U = U[idx,:]
    for i = 2:v.M+2
        dU[1,i]   = (U[i] - U[i-1])*invDx
        dU[2,i-1] = dU[1,i]
    end

    return superBee(v, dU, slopes)
end