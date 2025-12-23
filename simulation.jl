using Oceananigans
using Oceananigans.Units
using ClimaOcean
using SeawaterPolynomials.TEOS10
using FjordsSim
using NCDatasets

const FT = Oceananigans.defaults.FloatType

arch = GPU()
grid = ImmersedBoundaryGrid(
    "C:\\Users\\fisa\\Documents\\Isafjord\\input\\Isafjord_bathymetry_210x256.nc",
    arch,
    (7, 7, 7),
)
buoyancy = SeawaterBuoyancy(FT, equation_of_state=TEOS10EquationOfState(FT))
closure = (
    TKEDissipationVerticalDiffusivity(minimum_tke=7e-6),
    Oceananigans.TurbulenceClosures.HorizontalScalarBiharmonicDiffusivity(ν=15, κ=10),
)
# closure = Oceananigans.TurbulenceClosures.AnisotropicMinimumDissipation()
tracer_advection = (T=WENO(), S=WENO(), e=nothing, ϵ=nothing)
momentum_advection = WENOVectorInvariant(FT)
tracers = (:T, :S, :e, :ϵ)

# Load initial conditions from NetCDF
ini_path = "C:\\Users\\fisa\\Documents\\Isafjord\\input\\Isf_ini_210x256_B3-2016.nc"
ds_ini = NCDataset(ini_path)
T_ini = Float64.(coalesce.(ds_ini["T"][:, :, :, 1], 0.0))  # Replace missing with 0, convert to Float64
S_ini = Float64.(coalesce.(ds_ini["S"][:, :, :, 1], 0.0))
close(ds_ini)
initial_conditions = (T=T_ini, S=S_ini)

free_surface = SplitExplicitFreeSurface(grid, cfl=0.7)
coriolis = HydrostaticSphericalCoriolis(FT)
forcing = forcing_from_file(;
    grid=grid,
    filepath="C:\\Users\\fisa\\Documents\\Isafjord\\input\\Isf_bry_210x256rivers.nc",
    tracers=tracers,
)
tbbc = top_bottom_boundary_conditions(;
        grid=grid,
        bottom_drag_coefficient=0.003,
    )
sobc = (v = (north = OpenBoundaryCondition(nothing),),
    )

boundary_conditions = map(x -> FieldBoundaryConditions(;x...), recursive_merge(tbbc, sobc))
atmosphere = JRA55PrescribedAtmosphere(arch, FT;
        latitude = (65.76, 66.178),
        longitude = (-23.32, -22.3)
#    dir=joinpath(homedir(), "FjordsSim_data", "JRA55"),
)
downwelling_radiation = Radiation(arch, FT;
    ocean_emissivity=0.96,
    ocean_albedo=0.1
)
sea_ice = FreezingLimitedOceanTemperature()
biogeochemistry = nothing
results_dir = "C:\\Users\\fisa\\Documents\\Isafjord\\output\\3dec_T5_S34.5"
stop_time = 365days

simulation = coupled_hydrostatic_simulation(
    grid,
    buoyancy,
    closure,
    tracer_advection,
    momentum_advection,
    tracers,
    initial_conditions,
    free_surface,
    coriolis,
    forcing,
    boundary_conditions,
    atmosphere,
    downwelling_radiation,
    sea_ice,
    biogeochemistry;
    results_dir,
    stop_time,
)

simulation.callbacks[:progress] = Callback(progress, TimeInterval(5minutes))
ocean_sim = simulation.model.ocean
ocean_model = ocean_sim.model

atm_model = simulation.model.atmosphere

prefix = joinpath(results_dir, "snapshots_ocean_3dec")
atm_prefix = joinpath(results_dir, "snapshots_atmosphere_3dec")

ocean_sim.output_writers[:ocean] = NetCDFWriter(
    ocean_model,
    (
        T=ocean_model.tracers.T,
        S=ocean_model.tracers.S,
        u=ocean_model.velocities.u,
        v=ocean_model.velocities.v,
        w=ocean_model.velocities.w,
        ssh=ocean_model.free_surface.η,
    );
    filename = "$prefix",
    schedule = TimeInterval(24hours),
    overwrite_existing = true,
)

ocean_sim.output_writers[:atmosphere] = NetCDFWriter(
    ocean_model,
    (
        Ta=simulation.model.interfaces.net_fluxes.ocean_surface.T,
        ua=simulation.model.interfaces.net_fluxes.ocean_surface.u,
        va=simulation.model.interfaces.net_fluxes.ocean_surface.v,
    );
    filename = "$atm_prefix",
    schedule = TimeInterval(24hours),
    overwrite_existing = true,
)
ocean_sim.output_writers[:checkpointer] = Checkpointer(ocean_model; schedule=WallTimeInterval(1hour), cleanup=true, overwrite_existing = true)

conjure_time_step_wizard!(simulation; cfl = 0.1, max_Δt = 1minute, max_change = 1.01)
run!(simulation)
